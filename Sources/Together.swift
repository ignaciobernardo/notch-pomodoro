import Foundation
import MultipeerConnectivity

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
/// the transport is Wi-Fi: the shared network if there is one, otherwise Wi-Fi straight
/// between the Macs (the way AirDrop does it).
///
/// Nothing runs until you ask: discovery is on only while searching (max 2 min) and stops
/// at the first connection. Once connected, messages go out only when someone presses
/// something or edits their task.
final class Together: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let service = "notch-pomo"
    static let maxPeers = 7  // MPC sessions hold 8 including us

    private let me: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var stopWork: DispatchWorkItem?
    private var invitedByMe = Set<MCPeerID>()
    private var announced = Set<MCPeerID>()
    /// Stable random id, advertised so two Macs that find each other agree on who invites.
    private let uid: String

    private(set) var peers: [MCPeerID] = []
    var searching: Bool { advertiser != nil }
    var connected: Bool { !peers.isEmpty }

    // All callbacks arrive on the main thread.
    var onChange: (() -> Void)?
    /// A peer is nearby. The Bool says whether WE should invite them; the other side only waits.
    /// Only one side ever invites: two crossing invitations make MPC drop the link right after connecting.
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

    /// Look for people nearby. Already in a group: the same session stays open so whoever
    /// you find joins everyone.
    func search(seconds: Double = 120) {
        guard peers.count < Self.maxPeers else { return }
        stopSearching(notify: false)
        if session == nil {
            let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
            s.delegate = self
            session = s
        }
        announced = Set(peers)
        let info = ["id": uid, "g": connected ? "1" : "0"]
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.service)
        a.delegate = self
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
        b.delegate = self
        advertiser = a
        browser = b
        a.startAdvertisingPeer()
        b.startBrowsingForPeers()
        let w = DispatchWorkItem { [weak self] in self?.stopSearching(notify: true) }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        onChange?()
    }

    func stopSearching(notify: Bool = false) {
        stopWork?.cancel()
        stopWork = nil
        let was = searching
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        if !connected {
            session?.disconnect()
            session = nil
        }
        if was {
            onChange?()
            if notify && !connected { onSearchEnded?() }
        }
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
        stopSearching()
        let had = connected
        peers = []
        invitedByMe = []
        session?.disconnect()
        session = nil
        if had { onChange?() }
    }

    // MARK: browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard peerID != self.me, !self.peers.contains(peerID), !self.announced.contains(peerID) else { return }
            let theirID = info?["id"] ?? peerID.displayName
            let theirGroup = info?["g"] == "1"
            // A group grows from inside: whoever is already in one invites. Two groups don't merge.
            // Otherwise the smaller id invites, so both sides never invite each other.
            let weInvite: Bool
            if self.connected && theirGroup {
                self.log("found \(peerID.displayName), both in groups: ignored")
                return
            } else if self.connected != theirGroup {
                weInvite = self.connected
            } else {
                weInvite = self.uid < theirID
            }
            self.announced.insert(peerID)
            self.log("found \(peerID.displayName) (we invite: \(weInvite))")
            self.onFound?(peerID, weInvite)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    // MARK: advertiser

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            self.log("invitation from \(peerID.displayName)")
            // Already in a group: people join it through our own invitations, not by pulling us out.
            // Already inviting them: ours stands, theirs would cross it.
            guard let session = self.session, !self.connected, !self.invitedByMe.contains(peerID) else {
                self.log("declined invitation from \(peerID.displayName)")
                invitationHandler(false, nil)
                return
            }
            var answered = false
            self.onInvite?(peerID) { accept in
                guard !answered else { return }
                answered = true
                invitationHandler(accept, accept ? session : nil)
            }
        }
    }

    // MARK: session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.log("\(peerID.displayName): \(state == .connected ? "connected" : state == .connecting ? "connecting" : "not connected") (session \(session === self.session ? "current" : "stale"))")
            guard session === self.session else { return }
            switch state {
            case .connected:
                guard !self.peers.contains(peerID) else { return }
                self.peers.append(peerID)
                let mine = self.invitedByMe.remove(peerID) != nil
                // Stop discovery a moment later: tearing it down in the same instant can drop a fresh link.
                if self.searching {
                    self.stopWork?.cancel()
                    let w = DispatchWorkItem { [weak self] in self?.stopSearching() }
                    self.stopWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
                }
                self.onChange?()
                self.onConnected?(peerID, mine)
            case .notConnected:
                self.invitedByMe.remove(peerID)
                guard let i = self.peers.firstIndex(of: peerID) else { return }
                // A failed second attempt reports "not connected" while the real link is still up.
                if session.connectedPeers.contains(peerID) { return }
                self.peers.remove(at: i)
                if self.peers.isEmpty && !self.searching {
                    self.session?.disconnect()
                    self.session = nil
                }
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
    /// log show --last 30m --predicate 'process == "Pomodoro" AND eventMessage CONTAINS "[juntos]"'
    private func log(_ m: String) { NSLog("[juntos] %@", m) }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
