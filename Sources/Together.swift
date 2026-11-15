import Foundation
import MultipeerConnectivity
import os

/// What every notch in the group agrees on. Sent only when someone touches a control,
/// never per tick: each Mac runs its own timer from `left`, so clocks don't need to match.
struct SyncState: Codable, Equatable {
    var phase: String
    var running: Bool
    var left: Double
    var inSession: Bool
    var focusMin: Int
    var shortMin: Int
    var longMin: Int
    var cycle: Int
}

/// One message on the wire: the shared timer, the sender's task (shown in the
/// others' notches as their mini notch), or both.
struct Wire: Codable {
    var state: SyncState?
    var task: String?
}

/// "Pomodoros juntos" over MultipeerConnectivity, for a group of up to 8 Macs. On the Mac
/// the transport is Wi-Fi: the shared network if it lets Macs talk, otherwise Wi-Fi straight
/// between them (AWDL, the way AirDrop does it).
///
/// Two separate things:
/// - **discovery** (advertiser + browser) runs while you search AND for as long as you're in
///   a group. Stopping it makes macOS turn AWDL off, and a group linked over AWDL then dies
///   about 10 s later on a heartbeat timeout. It stops when you're alone and not searching.
/// - **searching** is what you see: for 2 minutes after you press the button, people nearby
///   are announced and invitations are taken. Outside it, discovery stays quiet.
///
/// Messages go out only when someone presses something or edits their task.
final class Together: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let service = "notch-pomo"
    static let maxPeers = 7  // MPC sessions hold 8 including us

    private let me: MCPeerID
    /// Stable random id, advertised so two Macs that find each other agree on who invites.
    private let uid: String
    private let logger = Logger(subsystem: "cl.natochi.notch-pomodoro", category: "juntos")
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var advertisedGroup = false
    private var browser: MCNearbyServiceBrowser?
    private var searchEnd: DispatchWorkItem?
    private var invitedByMe = Set<MCPeerID>()
    private var announced = Set<MCPeerID>()
    /// Everyone discovery currently sees, with what they advertise; announced when a search starts.
    private var nearby: [MCPeerID: [String: String]] = [:]

    private(set) var peers: [MCPeerID] = []
    private(set) var searching = false
    var connected: Bool { !peers.isEmpty }

    // All callbacks arrive on the main thread.
    var onChange: (() -> Void)?
    /// A peer is nearby. The Bool says whether WE should invite them; the other side only waits.
    /// Only one side ever invites: crossing invitations race and one of them tears the link down.
    var onFound: ((MCPeerID, Bool) -> Void)?
    var onInvite: ((MCPeerID, @escaping (Bool) -> Void) -> Void)?
    /// A peer joined; the Bool says whether we invited them (then we hand them the timer).
    var onConnected: ((MCPeerID, Bool) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onState: ((SyncState) -> Void)?
    var onPeerTask: ((MCPeerID, String) -> Void)?
    var onSearchEnded: (() -> Void)?

    override init() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "peerUID") {
            uid = saved
        } else {
            uid = UUID().uuidString
            d.set(uid, forKey: "peerUID")
        }
        let first = NSFullUserName().split(separator: " ").first.map { String($0).lowercased() }
        let name = first ?? Host.current().localizedName ?? "mac"
        if let data = d.data(forKey: "peerID"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           saved.displayName == name {
            me = saved
        } else {
            me = MCPeerID(displayName: name)
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: me, requiringSecureCoding: true) {
                d.set(data, forKey: "peerID")
            }
        }
        super.init()
    }

    // MARK: searching (what you see)

    /// Look for people nearby for `seconds`. Already in a group: whoever you find joins everyone.
    func search(seconds: Double = 120) {
        guard peers.count < Self.maxPeers else { return }
        startDiscovery()
        searching = true
        announced = Set(peers)
        searchEnd?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stopSearching(notify: true) }
        searchEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        log("search started (in group: \(connected))")
        onChange?()
        // Discovery may have been running quietly: announce who it already sees.
        for (peer, info) in nearby { announce(peer, info) }
    }

    func stopSearching(notify: Bool = false) {
        searchEnd?.cancel()
        searchEnd = nil
        guard searching else { return }
        searching = false
        log("search ended")
        if !connected { stopDiscovery() }
        onChange?()
        if notify && !connected { onSearchEnded?() }
    }

    // MARK: discovery (what keeps the link up)

    private func startDiscovery() {
        if session == nil {
            let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
            s.delegate = self
            session = s
        }
        // The advertised group flag decides who invites; refresh it if it went stale.
        if advertiser == nil || advertisedGroup != connected {
            advertiser?.stopAdvertisingPeer()
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["id": uid, "g": connected ? "1" : "0"],
                                              serviceType: Self.service)
            a.delegate = self
            a.startAdvertisingPeer()
            advertiser = a
            advertisedGroup = connected
        }
        if browser == nil {
            let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
        }
    }

    private func stopDiscovery() {
        log("discovery off")
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        nearby = [:]
        session?.disconnect()
        session = nil
        invitedByMe = []
    }

    func invite(_ peer: MCPeerID) {
        guard let session, let browser, !invitedByMe.contains(peer), !peers.contains(peer) else { return }
        invitedByMe.insert(peer)
        log("invite → \(peer.displayName)")
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    func send(state: SyncState? = nil, task: String? = nil, to target: [MCPeerID]? = nil) {
        let to = target ?? peers
        guard let session, !to.isEmpty, let data = try? JSONEncoder().encode(Wire(state: state, task: task)) else { return }
        try? session.send(data, toPeers: to, with: .reliable)
    }

    func leave() {
        let had = connected
        searchEnd?.cancel()
        searchEnd = nil
        searching = false
        peers = []
        stopDiscovery()
        if had { onChange?() }
    }

    private func announce(_ peer: MCPeerID, _ info: [String: String]) {
        guard searching, peer != me, !peers.contains(peer), !announced.contains(peer) else { return }
        let theirID = info["id"] ?? peer.displayName
        let theirGroup = info["g"] == "1"
        // A group grows from inside: whoever is already in one invites. Two groups don't merge.
        // Otherwise the smaller id invites, so the two sides never invite each other.
        let weInvite: Bool
        if connected && theirGroup {
            log("found \(peer.displayName), both in groups: ignored")
            return
        } else if connected != theirGroup {
            weInvite = connected
        } else {
            weInvite = uid < theirID
        }
        announced.insert(peer)
        log("found \(peer.displayName) (we invite: \(weInvite))")
        onFound?(peer, weInvite)
    }

    // MARK: browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard browser === self.browser, peerID != self.me else { return }
            self.nearby[peerID] = info ?? [:]
            self.announce(peerID, info ?? [:])
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.nearby[peerID] = nil
            self.announced.remove(peerID)
        }
    }

    // MARK: advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            self.log("invitation from \(peerID.displayName)")
            // Only while you're searching. Already in a group: people join it through our own
            // invitations, not by pulling us out. Already inviting them: ours stands.
            guard self.searching, let session = self.session, !self.connected, !self.invitedByMe.contains(peerID) else {
                self.log("declined invitation from \(peerID.displayName)")
                invitationHandler(false, nil)
                return
            }
            var answered = false
            self.onInvite?(peerID) { accept in
                guard !answered else { return }
                answered = true
                self.log("\(accept ? "accepted" : "declined") invitation from \(peerID.displayName)")
                invitationHandler(accept, accept ? session : nil)
            }
        }
    }

    // MARK: session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            let name = state == .connected ? "connected" : state == .connecting ? "connecting" : "not connected"
            self.log("\(peerID.displayName): \(name)\(session === self.session ? "" : " (stale session)")")
            guard session === self.session else { return }
            switch state {
            case .connected:
                guard !self.peers.contains(peerID) else { return }
                self.peers.append(peerID)
                let mine = self.invitedByMe.remove(peerID) != nil
                // The search is over, but discovery stays on while in a group (see the type's doc).
                self.searching = false
                self.searchEnd?.cancel()
                self.searchEnd = nil
                self.onChange?()
                self.onConnected?(peerID, mine)
            case .notConnected:
                self.invitedByMe.remove(peerID)
                guard let i = self.peers.firstIndex(of: peerID) else { return }
                // A failed second attempt reports "not connected" while the real link is still up.
                if session.connectedPeers.contains(peerID) { return }
                self.peers.remove(at: i)
                if self.peers.isEmpty && !self.searching { self.stopDiscovery() }
                self.onChange?()
                self.onDisconnected?(peerID)
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        DispatchQueue.main.async {
            guard self.peers.contains(peerID) else { return }
            if let t = wire.task { self.onPeerTask?(peerID, t) }
            if let s = wire.state { self.onState?(s) }
        }
    }

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
                 certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }

    /// Connection events only (never per tick). Read them with:
    /// /usr/bin/log show --last 30m --predicate 'subsystem == "cl.natochi.notch-pomodoro"'
    private func log(_ m: String) { logger.notice("\(m, privacy: .public)") }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
