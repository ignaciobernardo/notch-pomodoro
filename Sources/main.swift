import AppKit
import MultipeerConnectivity
import ServiceManagement
import SwiftUI

/// Borderless, non-activating panel above the menu bar: never steals focus from the app you're in.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HostView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Hover comes from one tracking area on a window that is sized to the notch,
/// so there is no mouse polling and no global event monitor.
final class TrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea!

    override init(frame: NSRect) {
        super.init(frame: frame)
        area = NSTrackingArea(rect: .zero,
                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                              owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    // SwiftUI's own hover areas bubble their events up here too; only react to ours.
    override func mouseEntered(with event: NSEvent) { if event.trackingArea === area { onEnter?() } }
    override func mouseExited(with event: NSEvent) { if event.trackingArea === area { onExit?() } }
}

final class MenuAction: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func run() { fn() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let env = ProcessInfo.processInfo.environment
    lazy var logURL: URL = {
        if let p = env["POMO_LOG"] ?? UserDefaults.standard.string(forKey: "logPath") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/pomodoros.md")
    }()
    let calendar = CalendarSync()
    let together = Together()
    let updater = Updater()
    var peerTasks: [MCPeerID: String] = [:]
    var sendQueued = false
    var toastExpire: (() -> Void)?
    var finishToast: UUID?
    var snapshotting = false
    var bubbleWork: [UUID: DispatchWorkItem] = [:]
    lazy var pomo = Pomodoro(log: MarkdownLog(url: logURL), unit: env["POMO_FAST"] == "1" ? 1 : 60)
    let ui = NotchUI()
    var panel: NotchPanel!
    var host: HostView<NotchView>!
    var screen: NSScreen?
    var notchMidX: CGFloat = 0
    var target = CGSize.zero
    var scrollAcc: CGFloat = 0
    static let canvas = CGSize(width: 720, height: 240)
    var toastAction: (() -> Void)?
    var expandWork: DispatchWorkItem?
    var collapseWork: DispatchWorkItem?
    var shrinkWork: DispatchWorkItem?
    var toastWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = NotchPanel()
        panel.delegate = self
        let root = NotchView(ui: ui, pomo: pomo,
                             onToastAction: { [weak self] in self?.runToastAction() },
                             onEndEditing: { [weak self] in self?.endEditing() },
                             onTogether: { [weak self] in self?.togetherTapped() },
                             onOpenChat: { [weak self] in self?.openChat() },
                             onCloseChat: { [weak self] in self?.closeChat() },
                             onSend: { [weak self] text in self?.sendChat(text) })
        host = HostView(rootView: root)
        host.sizingOptions = []
        host.menuProvider = { [weak self] in self?.menu() ?? NSMenu() }
        let container = TrackingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.onEnter = { [weak self] in self?.mouseEntered() }
        container.onExit = { [weak self] in self?.mouseExited() }
        // Fixed-size SwiftUI canvas: the window grows and shrinks around it, but SwiftUI
        // never relayouts, so the shell can't slide while its spring is running.
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        host.autoresizingMask = []
        container.addSubview(host)
        panel.contentView = container

        measureNotch()
        ui.onSize = { [weak self] s in self?.fit(s) }
        pomo.onFinish = { [weak self] p in self?.finished(p) }
        pomo.onFocusDone = { [weak self] start, end, task, mins in
            self?.calendar.addFocus(start: start, end: end, task: task, minutes: mins)
        }
        pomo.restore()
        setupTogether()

        place(ui.notch)
        if env["POMO_SNAPSHOT"] != nil || env["POMO_HEADLESS"] == "1" {
            // Renders go through ImageRenderer / tests run unseen: keep the window invisible and out of the way.
            panel.alphaValue = 0
            snapshotting = true
        }
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.measureNotch()
            self.place(self.panel.frame.size)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.pomo.resync()
        }

        // Scroll over the open notch while editing the time = − / +. Local monitor: only
        // sees events already headed to this app, costs nothing otherwise.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.ui.expanded, self.ui.editingTime else { return e }
            if e.momentumPhase != [] { return nil }
            let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
            self.scrollAcc += e.hasPreciseScrollingDeltas ? dy / 16 : dy
            while self.scrollAcc >= 1 { self.pomo.adjust(1); self.scrollAcc -= 1 }
            while self.scrollAcc <= -1 { self.pomo.adjust(-1); self.scrollAcc += 1 }
            return nil
        }

        if let dir = env["POMO_SNAPSHOT"] {
            Snapshot.run(app: self, dir: dir)
        } else {
            updater.onAvailable = { [weak self] r in
                guard let self, self.ui.toast == nil else { return }
                self.toastAction = { [weak self] in self?.installUpdate() }
                self.show(Toast(icon: .update, title: "versión \(r.version) disponible", action: "actualizar"), seconds: 12)
            }
            updater.start()
        }
    }

    func installUpdate() {
        show(Toast(icon: .update, title: "actualizando…", action: nil), seconds: 90)
        updater.install { [weak self] msg in
            self?.show(Toast(icon: .info, title: "no se pudo actualizar: \(msg)", action: nil), seconds: 6)
        }
    }

    func checkForUpdates() {
        updater.check { [weak self] found in
            guard let self else { return }
            switch found {
            case .some(true):
                self.toastAction = { [weak self] in self?.installUpdate() }
                self.show(Toast(icon: .update, title: "versión \(self.updater.available?.version ?? "") disponible", action: "actualizar"), seconds: 12)
            case .some(false):
                self.show(Toast(icon: .success, title: "estás al día · \(self.updater.current)", action: nil), seconds: 4)
            case .none:
                self.show(Toast(icon: .info, title: "no pude revisar actualizaciones", action: nil), seconds: 4)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        together.leave()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        setExpanded(true)
        // Opened from Spotlight/Finder with the mouse elsewhere: no exit event will come.
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInside, !self.ui.editing else { return }
            self.setExpanded(false)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
        return false
    }

    // MARK: window geometry

    /// Finds the camera housing from the menu-bar areas on either side of it.
    /// Screens without one get a stand-in notch the height of the menu bar.
    func measureNotch() {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let scr = notched ?? NSScreen.screens.first
        screen = scr
        guard let scr else { return }
        if let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea, scr.safeAreaInsets.top > 0 {
            ui.notch = CGSize(width: r.minX - l.maxX, height: scr.safeAreaInsets.top)
            notchMidX = scr.frame.minX + (l.maxX + r.minX) / 2
        } else {
            let bar = max(24, scr.frame.maxY - scr.visibleFrame.maxY)
            ui.notch = CGSize(width: 180, height: bar)
            notchMidX = scr.frame.midX
        }
    }

    /// Grow the window immediately, shrink it only after the spring has settled.
    /// While a collapse is settling the leftover transparent area ignores the mouse,
    /// otherwise lingering just below the notch would re-open it in a loop.
    func fit(_ s: CGSize) {
        trace("fit \(s)")
        let mode = ui.mode(pomo)
        let open = NotchUI.isOpen(mode)
        let e = NotchUI.shape(mode).ear
        target = CGSize(width: ceil(s.width + 2 * e), height: ceil(s.height))
        // Room for the opening spring's overshoot, trimmed once it settles.
        let pad = open ? CGSize(width: 24, height: 10) : .zero
        let cur = panel.frame.size
        let now = CGSize(width: max(cur.width, target.width + pad.width),
                         height: max(cur.height, target.height + pad.height))
        if now != cur { place(now) }
        shrinkWork?.cancel()
        guard now != target else {
            panel.ignoresMouseEvents = snapshotting
            return
        }
        panel.ignoresMouseEvents = snapshotting || !open
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.place(self.target)
            if self.panel.ignoresMouseEvents {
                self.panel.ignoresMouseEvents = false
                if self.mouseInside { self.mouseEntered() }
            }
        }
        shrinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func place(_ size: CGSize) {
        guard let scr = screen else { return }
        let x = notchMidX - size.width / 2
        panel.setFrame(NSRect(x: x, y: scr.frame.maxY - size.height, width: size.width, height: size.height),
                       display: false)
        // Keep the canvas centered on the notch and pinned to the top edge.
        host.setFrameOrigin(NSPoint(x: (size.width - Self.canvas.width) / 2,
                                    y: size.height - Self.canvas.height))
        panel.display()
    }

    var mouseInside: Bool { panel.frame.contains(NSEvent.mouseLocation) }

    // MARK: hover

    func trace(_ m: String) {
        if env["POMO_TRACE"] != nil {
            FileHandle.standardError.write("\(String(format: "%.2f", CACurrentMediaTime())) \(m) mouse=\(NSEvent.mouseLocation) frame=\(panel.frame)\n".data(using: .utf8)!)
        }
    }

    func mouseEntered() {
        trace("entered")
        collapseWork?.cancel()
        guard !ui.expanded, !ui.chatOpen, ui.toast == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.setExpanded(true) }
        expandWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    func mouseExited() {
        trace("exited")
        expandWork?.cancel()
        guard ui.expanded || ui.chatOpen, !ui.editing else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInside, !self.ui.editing else { return }
            self.closeChat()
            self.setExpanded(false)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func setExpanded(_ v: Bool) {
        guard ui.expanded != v else { return }
        withAnimation(v ? openSpring : fluid) {
            ui.expanded = v
            if !v { ui.editingTime = false }
        }
    }

    /// Ends task editing and hands keyboard focus back to whatever app you were in.
    func endEditing() {
        ui.editing = false
        pomo.saveTask()
        together.send(task: pomo.task)
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if !mouseInside { setExpanded(false) }
    }

    func windowDidResignKey(_ n: Notification) {
        guard ui.editing else { return }
        ui.editing = false
        if ui.chatOpen {
            if !mouseInside { closeChat() }
            return
        }
        pomo.saveTask()
        together.send(task: pomo.task)
        if !mouseInside { setExpanded(false) }
    }

    // MARK: toasts

    var soundOn: Bool {
        get { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }

    /// Loaded on demand and released after playing: nothing held in memory while idle.
    func chime(_ name: String) {
        guard soundOn, let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            if soundOn { NSSound(named: "Glass")?.play() }
            return
        }
        NSSound(contentsOf: url, byReference: true)?.play()
    }

    func finished(_ p: Phase) {
        chime(p == .focus ? "focus-done" : "break-done")
        let t: Toast
        if p == .focus {
            let m = pomo.seconds(.focus)
            let amount = pomo.unit == 1 ? "\(m) s" : "\(m / 60) min"
            t = Toast(icon: .success, title: "foco listo · \(amount)",
                      action: pomo.phase == .long ? "descanso largo" : "descansar")
        } else {
            t = Toast(icon: .info, title: "se acabó el descanso", action: "enfocarse")
        }
        toastAction = { [weak self] in withAnimation(fluid) { self?.pomo.start() } }
        show(t, seconds: 8)
        finishToast = t.id
    }

    /// `onExpire` runs if the toast times out or another toast replaces it without its action being used.
    func show(_ t: Toast, seconds: Double, onExpire: (() -> Void)? = nil) {
        let previous = toastExpire
        toastExpire = onExpire
        previous?()
        if t.action == nil { toastAction = nil }
        withAnimation(fluid) { ui.toast = t }
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toastTimedOut() }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func toastTimedOut() {
        let e = toastExpire
        toastExpire = nil
        toastAction = nil
        e?()
        dismissToast()
    }

    func dismissToast() {
        toastWork?.cancel()
        withAnimation(fluid) {
            ui.toast = nil
            ui.expanded = mouseInside
        }
    }

    func runToastAction() {
        let a = toastAction
        toastAction = nil
        toastExpire = nil
        dismissToast()
        a?()
    }

    // MARK: chat

    func openChat() {
        guard together.connected || snapshotting else { return }
        collapseWork?.cancel()
        bubbleWork.values.forEach { $0.cancel() }
        bubbleWork = [:]
        withAnimation(openSpring) {
            ui.bubbles = []
            ui.unread = 0
            ui.chatOpen = true
        }
        // Key window for the message field; the app itself stays in the background.
        panel.makeKey()
    }

    func closeChat() {
        guard ui.chatOpen else { return }
        ui.editing = false
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        withAnimation(fluid) {
            ui.chatOpen = false
            ui.expanded = mouseInside
        }
    }

    func sendChat(_ text: String) {
        together.send(msg: text)
        withAnimation(fluid) { appendMessage(ChatMessage(from: "tú", text: text, mine: true)) }
    }

    /// Chat open: it lands in the list. Closed: it peeks out under the camera for 6 s and blurs away.
    func receiveChat(from name: String, _ text: String) {
        let m = ChatMessage(from: name, text: text, mine: false)
        withAnimation(fluid) { appendMessage(m) }
        guard !ui.chatOpen else { return }
        if soundOn && !snapshotting { NSSound(named: "Tink")?.play() }
        withAnimation(openSpring) {
            ui.unread += 1
            ui.bubbles.append(m)
            if ui.bubbles.count > 3 { ui.bubbles.removeFirst(ui.bubbles.count - 3) }
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bubbleWork[m.id] = nil
            withAnimation(fluid) { self.ui.bubbles.removeAll { $0.id == m.id } }
        }
        bubbleWork[m.id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    func appendMessage(_ m: ChatMessage) {
        ui.messages.append(m)
        if ui.messages.count > 40 { ui.messages.removeFirst(ui.messages.count - 40) }
    }

    // MARK: juntos

    func setupTogether() {
        let t = together
        t.onChange = { [weak self] in self?.syncMates() }
        t.onFound = { [weak self] peer, weInvite in
            guard let self else { return }
            guard weInvite else {
                // The other Mac invites; we just wait for its invitation to arrive.
                self.show(Toast(icon: .people, title: "\(peer.displayName) está cerca · esperando que conecte", action: nil), seconds: 20)
                return
            }
            self.toastAction = { [weak self] in
                guard let self else { return }
                self.together.invite(peer)
                self.show(Toast(icon: .people, title: "esperando a \(peer.displayName)…", action: nil), seconds: 30)
            }
            self.show(Toast(icon: .people, title: "\(peer.displayName) está cerca", action: "conectar"), seconds: 20)
        }
        t.onInvite = { [weak self] peer, reply in
            guard let self else { reply(false); return }
            NSSound(named: "Pop")?.play()
            self.toastAction = { reply(true) }
            self.show(Toast(icon: .people, title: "\(peer.displayName) quiere hacer pomodoros juntos", action: "aceptar"),
                      seconds: 30, onExpire: { reply(false) })
        }
        t.onConnected = { [weak self] peer, invitedByMe in
            guard let self else { return }
            self.together.send(task: self.pomo.task, to: [peer])
            // Whoever invited hands over their timer; the newcomer adopts it.
            if invitedByMe { self.together.send(state: self.pomo.snapshot(), to: [peer]) }
            let title = self.together.peers.count > 1 ? "\(peer.displayName) se unió" : "juntos con \(peer.displayName)"
            self.show(Toast(icon: .success, title: title, action: nil), seconds: 4)
        }
        t.onDisconnected = { [weak self] peer in
            guard let self else { return }
            self.peerTasks[peer] = nil
            self.syncMates()
            self.show(Toast(icon: .info, title: "\(peer.displayName) se fue", action: nil), seconds: 4)
        }
        t.onState = { [weak self] state in
            guard let self else { return }
            withAnimation(fluid) { self.pomo.adopt(state) }
            // Someone already pressed "descansar"/"enfocarse": our copy of that toast is done.
            if self.pomo.running, let id = self.finishToast, self.ui.toast?.id == id {
                self.toastAction = nil
                self.dismissToast()
            }
        }
        t.onPeerTask = { [weak self] peer, task in
            self?.peerTasks[peer] = task
            self?.syncMates()
        }
        t.onPeerMessage = { [weak self] peer, text in self?.receiveChat(from: peer.displayName, text) }
        t.onSearchEnded = { [weak self] in
            self?.show(Toast(icon: .info, title: "no encontré a nadie cerca", action: nil), seconds: 4)
        }
        pomo.onLocalChange = { [weak self] in self?.queueSend() }

        // Debug (two copies on one Mac): search at launch, invite and accept on their own.
        if env["POMO_JUNTOS_AUTO"] == "1" {
            let found = t.onFound, invited = t.onInvite
            t.onFound = { [weak self] peer, weInvite in
                found?(peer, weInvite)
                if weInvite { self?.together.invite(peer) }
            }
            t.onInvite = { peer, reply in
                invited?(peer, reply)
                reply(true)
            }
            let joined = t.onConnected
            t.onConnected = { [weak self] peer, mine in
                joined?(peer, mine)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.sendChat("hola") }
            }
            t.search(seconds: 60)
        }
    }

    func syncMates() {
        ui.searching = together.searching
        peerTasks = peerTasks.filter { together.peers.contains($0.key) }
        let mates = together.peers.map { Mate(id: "\($0.hash)", name: $0.displayName, task: peerTasks[$0] ?? "") }
        if mates != ui.mates { withAnimation(fluid) { ui.mates = mates } }
    }

    /// One message per run-loop turn, however many settings a single tap touched.
    func queueSend() {
        guard together.connected, !sendQueued else { return }
        sendQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sendQueued = false
            self.together.send(state: self.pomo.snapshot())
        }
    }

    /// The people button: look for someone nearby, or for one more person if you're already a group.
    func togetherTapped() {
        if together.searching {
            together.stopSearching()
            return
        }
        guard together.peers.count < Together.maxPeers else { return }
        together.search()
        toastAction = { [weak self] in self?.together.stopSearching() }
        show(Toast(icon: .people, title: together.connected ? "buscando a alguien más…" : "buscando a alguien cerca…",
                   action: "cancelar"), seconds: 5)
    }

    func togetherItem(_ item: (String, Bool, @escaping () -> Void) -> NSMenuItem) -> NSMenuItem {
        let top = NSMenuItem(title: together.connected ? "juntos · \(ui.people)" : "juntos", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if together.connected {
            let names = together.peers.map(\.displayName).joined(separator: ", ")
            let who = NSMenuItem(title: "con \(names)", action: nil, keyEquivalent: "")
            who.isEnabled = false
            sub.addItem(who)
            sub.addItem(item(together.searching ? "dejar de buscar" : "buscar a alguien más", false) { [weak self] in
                self?.togetherTapped()
            })
            sub.addItem(item("salir del grupo", false) { [weak self] in
                guard let self else { return }
                self.together.leave()
                self.syncMates()
                self.show(Toast(icon: .info, title: "saliste del grupo", action: nil), seconds: 3)
            })
        } else {
            sub.addItem(item(together.searching ? "dejar de buscar" : "buscar a alguien cerca", false) { [weak self] in
                self?.togetherTapped()
            })
        }
        top.submenu = sub
        return top
    }

    // MARK: menu (right click)

    // MARK: calendar

    /// "calendario" submenu: on/off plus which calendar the pomodoros go to.
    func calendarItem(_ item: (String, Bool, @escaping () -> Void) -> NSMenuItem) -> NSMenuItem {
        let cal = calendar
        let top = NSMenuItem(title: "calendario", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if cal.denied {
            top.title = "calendario · sin permiso"
            sub.addItem(item("dar permiso en ajustes…", false) {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(u)
                }
            })
        } else if !cal.authorized {
            sub.addItem(item("agregar pomodoros al calendario", false) {
                NSApp.activate()
                cal.requestAccess { ok in cal.enabled = ok }
            })
        } else {
            let name = cal.currentTitle()
            if cal.enabled, let name { top.title = "calendario · \(name)" }
            sub.addItem(item("agregar pomodoros al calendario", cal.enabled) { cal.enabled.toggle() })
            sub.addItem(.separator())
            var lastAccount = ""
            for c in cal.calendars() {
                if c.account != lastAccount {
                    let h = NSMenuItem(title: c.account, action: nil, keyEquivalent: "")
                    h.isEnabled = false
                    sub.addItem(h)
                    lastAccount = c.account
                }
                let isOn = cal.calendarID == c.id || (cal.calendarID == nil && c.title == name)
                let i = item(c.title, isOn) { cal.calendarID = c.id; cal.enabled = true }
                i.indentationLevel = 1
                sub.addItem(i)
            }
        }
        top.submenu = sub
        return top
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        func item(_ title: String, on: Bool = false, _ fn: @escaping () -> Void) -> NSMenuItem {
            let a = MenuAction(fn)
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            i.target = a
            i.representedObject = a
            i.state = on ? .on : .off
            return i
        }
        func minutes(_ title: String, _ options: [Int], _ get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> NSMenuItem {
            let sub = NSMenu()
            for v in options { sub.addItem(item("\(v) min", on: get() == v) { set(v) }) }
            let i = NSMenuItem(title: "\(title) · \(get()) min", action: nil, keyEquivalent: "")
            i.submenu = sub
            return i
        }

        let p = pomo
        m.addItem(minutes("foco", [15, 20, 25, 30, 45, 50, 60], { p.focusMin }, { p.focusMin = $0 }))
        m.addItem(minutes("descanso", [3, 5, 10, 15], { p.shortMin }, { p.shortMin = $0 }))
        m.addItem(minutes("descanso largo", [10, 15, 20, 30], { p.longMin }, { p.longMin = $0 }))
        m.addItem(item("reiniciar ciclo") { p.resetCycle() })
        m.addItem(.separator())
        m.addItem(item("abrir registro") { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: self.logURL.path) {
                try? FileManager.default.createDirectory(at: self.logURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? "# pomodoros\n".write(to: self.logURL, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(self.logURL)
        })
        m.addItem(item("mostrar en finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.logURL])
        })
        m.addItem(togetherItem(item))
        m.addItem(calendarItem(item))
        m.addItem(item("sonido", on: soundOn) { [weak self] in self?.soundOn.toggle() })
        m.addItem(item("probar sonido") { [weak self] in
            guard let self else { return }
            let was = self.soundOn
            self.soundOn = true
            self.chime("focus-done")
            self.soundOn = was
        })
        m.addItem(.separator())
        let login = SMAppService.mainApp.status == .enabled
        m.addItem(item("abrir al iniciar sesión", on: login) {
            if login { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        })
        if let r = updater.available {
            m.addItem(item("actualizar a \(r.version)") { [weak self] in self?.installUpdate() })
        } else {
            m.addItem(item("buscar actualizaciones") { [weak self] in self?.checkForUpdates() })
        }
        let v = NSMenuItem(title: "versión \(updater.current)", action: nil, keyEquivalent: "")
        v.isEnabled = false
        m.addItem(v)
        m.addItem(item("salir") { NSApp.terminate(nil) })
        return m
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
