import AppKit
import Observation
import SwiftUI

// Motion and metrics from notch-toast (MIT): "fluid" spring, ease [0.16, 1, 0.3, 1],
// inverse-fillet ears where the shape meets the screen edge, 14px semibold labels.
let fluid = Animation.interpolatingSpring(mass: 0.62, stiffness: 400, damping: 32)
let quickOut = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.1)
let easeOut = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
/// Opening: a touch of overshoot so it reads as the notch itself growing (Dynamic Island feel).
/// Closing uses the critically damped `fluid` so it tucks back into the camera without wobble.
let openSpring = Animation.interpolatingSpring(mass: 0.62, stiffness: 380, damping: 25)
/// Focus is black like the hardware notch; breaks turn it celeste with deep navy ink.
struct Palette: Equatable {
    var bg: Color
    var fg: Color
    var dim: Color

    static let focus = Palette(bg: .black, fg: .white, dim: Color.white.opacity(0.5))
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.focus }

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}


private let hasGeist = NSFontManager.shared.availableFontFamilies.contains("Geist")

func geist(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    hasGeist ? .custom("Geist", size: size).weight(weight) : .system(size: size, weight: weight)
}

struct Toast: Equatable {
    enum Icon { case success, info, people, update }
    let id = UUID()
    var icon: Icon
    var title: String
    var action: String?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let from: String
    let text: String
    let mine: Bool
}

/// iMessage green, the one colour the notch allows itself.
let bubbleGreen = Color(red: 0.204, green: 0.78, blue: 0.349)

struct Mate: Identifiable, Equatable {
    let id: String
    var name: String
    var task: String
}

@Observable
final class NotchUI {
    enum Mode: Equatable { case idle, live, expanded, chat, bubbles, toast(UUID) }

    var expanded = false
    var toast: Toast?
    var editing = false
    var editingTime = false
    var size: CGSize = .zero
    var snapshot = false
    /// The hardware notch (or a stand-in on screens without one).
    var notch = CGSize(width: 185, height: 32)
    /// People in your "juntos" group (not you), each with what they're working on.
    var mates: [Mate] = []
    var searching = false
    var people: Int { mates.count + 1 }
    /// The group chat: history of this session, the chat panel, and bubbles popping while it's closed.
    var messages: [ChatMessage] = []
    var chatOpen = false
    var bubbles: [ChatMessage] = []
    var unread = 0

    @ObservationIgnored var onSize: ((CGSize) -> Void)?

    func mode(_ pomo: Pomodoro) -> Mode {
        if let t = toast { return .toast(t.id) }
        if chatOpen { return .chat }
        if !bubbles.isEmpty { return .bubbles }
        if expanded { return .expanded }
        return pomo.isIdle ? .idle : .live
    }

    /// Ear (concave flare into the top edge) and bottom corner radius per state.
    /// Collapsed it echoes the hardware notch; open it uses notch-toast's softer curve.
    static func shape(_ m: Mode) -> (ear: CGFloat, radius: CGFloat) {
        switch m {
        case .idle: return (0, 9)
        case .live: return (6, 11)
        case .expanded, .toast, .chat, .bubbles: return (14, 22)
        }
    }

    static func isOpen(_ m: Mode) -> Bool {
        if case .idle = m { return false }
        if case .live = m { return false }
        return true
    }
}

// MARK: shell

struct NotchView: View {
    @Bindable var ui: NotchUI
    @Bindable var pomo: Pomodoro
    var onToastAction: () -> Void
    var onEndEditing: () -> Void
    var onTogether: () -> Void
    var onOpenChat: () -> Void = {}
    var onCloseChat: () -> Void = {}
    var onSend: (String) -> Void = { _ in }

    var body: some View {
        let mode = ui.mode(pomo)
        let s = NotchUI.shape(mode)
        let pal = Palette.focus
        ZStack(alignment: .top) {
            NotchShape(ear: s.ear, radius: s.radius)
                .fill(pal.bg)
                .frame(width: ui.size.width + 2 * s.ear, height: ui.size.height)

            ZStack(alignment: .top) { content(mode) }
                .frame(width: ui.size.width, height: ui.size.height, alignment: .top)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: s.radius, bottomTrailingRadius: s.radius))
        }
        // The canvas never changes size (see AppDelegate.place), so the shell stays
        // pinned to the notch and only its own size/shape animate.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchUI.isOpen(mode) ? openSpring : fluid, value: ui.size)
        .animation(NotchUI.isOpen(mode) ? openSpring : fluid, value: mode)
        .foregroundStyle(pal.fg)
        .environment(\.palette, pal)
    }

    @ViewBuilder private func content(_ mode: NotchUI.Mode) -> some View {
        switch mode {
        case .toast:
            if let t = ui.toast {
                ToastView(toast: t, notch: ui.notch, onAction: onToastAction)
                    .measured(ui).id(t.id).transition(.slot)
            }
        case .expanded:
            ExpandedView(ui: ui, pomo: pomo, onEndEditing: onEndEditing, onTogether: onTogether, onOpenChat: onOpenChat)
                .measured(ui).transition(.slot)
        case .chat:
            ChatView(ui: ui, onSend: onSend, onClose: onCloseChat)
                .measured(ui).transition(.slot)
        case .bubbles:
            BubblesView(ui: ui, onOpen: onOpenChat)
                .measured(ui).transition(.slot)
        case .live:
            LiveView(pomo: pomo, notch: ui.notch, people: ui.people, unread: ui.unread)
                .measured(ui).transition(.slot)
        case .idle:
            // Sits just inside the hardware notch: invisible until you hover it.
            Color.clear
                .frame(width: ui.notch.width - 2, height: ui.notch.height - 1)
                .measured(ui).transition(.identity)
        }
    }
}

/// Top-attached notch: bottom corners rounded, top corners flare into the screen
/// edge with concave quarter circles (notch-toast's `:before`/`:after` ears).
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width - 2 * ear
        let h = rect.height
        guard w > 1, h > 1 else { return Path() }
        let r = min(radius, w / 2, h / 2)
        let e = min(ear, max(0, h - r))
        let k: CGFloat = 0.5523  // cubic quarter-circle constant
        let l = rect.minX + ear, rt = rect.maxX - ear
        let t = rect.minY, b = rect.maxY

        var p = Path()
        p.move(to: CGPoint(x: l - e, y: t))
        p.addCurve(to: CGPoint(x: l, y: t + e),
                   control1: CGPoint(x: l - e + k * e, y: t),
                   control2: CGPoint(x: l, y: t + e - k * e))
        p.addLine(to: CGPoint(x: l, y: b - r))
        p.addCurve(to: CGPoint(x: l + r, y: b),
                   control1: CGPoint(x: l, y: b - r + k * r),
                   control2: CGPoint(x: l + r - k * r, y: b))
        p.addLine(to: CGPoint(x: rt - r, y: b))
        p.addCurve(to: CGPoint(x: rt, y: b - r),
                   control1: CGPoint(x: rt - r + k * r, y: b),
                   control2: CGPoint(x: rt, y: b - r + k * r))
        p.addLine(to: CGPoint(x: rt, y: t + e))
        p.addCurve(to: CGPoint(x: rt + e, y: t),
                   control1: CGPoint(x: rt, y: t + e - k * e),
                   control2: CGPoint(x: rt + e - k * e, y: t))
        p.closeSubpath()
        return p
    }
}

struct Reveal: ViewModifier {
    var hidden: Bool
    var y: CGFloat
    var scale: CGFloat
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? blur : 0)
            .scaleEffect(hidden ? scale : 1, anchor: .top)
            .offset(y: hidden ? y : 0)
            .opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    /// notch-toast content slot (top variant): in with blur + drop on the spring, out fast.
    static let slot = AnyTransition.asymmetric(
        insertion: .modifier(active: Reveal(hidden: true, y: -7, scale: 0.92, blur: 5),
                             identity: Reveal(hidden: false, y: -7, scale: 0.92, blur: 5)).animation(fluid.delay(0.05)),
        removal: .modifier(active: Reveal(hidden: true, y: -7, scale: 0.92, blur: 0),
                           identity: Reveal(hidden: false, y: -7, scale: 0.92, blur: 0)).animation(quickOut))
}

extension View {
    func measured(_ ui: NotchUI) -> some View {
        fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { s in
            ui.size = s
            ui.onSize?(s)
        }
    }
}

// MARK: states

/// Running or paused, collapsed: two wings either side of the camera.
struct LiveView: View {
    @Environment(\.palette) private var pal
    var pomo: Pomodoro
    var notch: CGSize
    var people = 1
    var unread = 0
    /// Wider wings while in a group, to fit the people icon and the chat logo beside the ring.
    static func wing(_ people: Int) -> CGFloat { people > 1 ? 98 : 58 }

    var body: some View {
        let wing = Self.wing(people)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if pomo.phase.isBreak {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 11, weight: .semibold))
                } else {
                    Ring(progress: pomo.progress)
                }
                if people > 1 {
                    PeopleIcon(count: people)
                    Image(systemName: unread > 0 ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(unread > 0 ? bubbleGreen : (pomo.running ? pal.fg : pal.dim))
                }
            }
            .foregroundStyle(pomo.running ? pal.fg : pal.dim)
            .padding(.leading, 14)
            .frame(width: wing, alignment: .leading)

            Color.clear.frame(width: notch.width)

            // No digit animation here: collapsed, it only redraws a few glyphs per second.
            Text(clock(pomo.remaining))
                .font(geist(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(pomo.running ? pal.fg : pal.dim)
                .padding(.trailing, 14)
                .frame(width: wing, alignment: .trailing)
        }
        .frame(height: notch.height)
    }
}

struct ExpandedView: View {
    @Environment(\.palette) private var pal
    @Bindable var ui: NotchUI
    @Bindable var pomo: Pomodoro
    var onEndEditing: () -> Void
    var onTogether: () -> Void
    var onOpenChat: () -> Void = {}
    @FocusState private var focused: Bool

    private var togetherSymbol: String {
        if ui.people >= 3 { return "person.3.fill" }
        if ui.people == 2 { return "person.2.fill" }
        return ui.searching ? "dot.radiowaves.left.and.right" : "person.2"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Band beside the camera: label on the left wing, cycle on the right.
            HStack(spacing: 0) {
                Text(pomo.phase.label).foregroundStyle(pal.dim)
                Spacer(minLength: ui.notch.width + 16)
                Dots(done: pomo.cycle)
            }
            .font(geist(12, .semibold))
            .frame(height: ui.notch.height)

            HStack(spacing: 6) {
                // Click the time to change it: reset/skip turn into − / + (scroll works too).
                Button {
                    withAnimation(easeOut) { ui.editingTime.toggle() }
                } label: {
                    Text(clock(pomo.remaining))
                        .font(geist(42, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(pomo.remaining)))
                        .animation(easeOut, value: pomo.remaining)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 16)
                if ui.editingTime {
                    RoundButton(symbol: "minus") { pomo.adjust(-1) }
                        .transition(.blurReplace)
                    RoundButton(symbol: "plus") { pomo.adjust(1) }
                        .transition(.blurReplace)
                } else {
                    RoundButton(symbol: togetherSymbol, active: ui.people > 1 || ui.searching) { onTogether() }
                        .transition(.blurReplace)
                    if ui.people > 1 {
                        RoundButton(symbol: ui.unread > 0 ? "bubble.left.fill" : "bubble.left", active: ui.unread > 0) { onOpenChat() }
                            .transition(.blurReplace)
                    }
                    RoundButton(symbol: "arrow.counterclockwise") { withAnimation(fluid) { pomo.reset() } }
                        .transition(.blurReplace)
                    RoundButton(symbol: "forward.end.fill") { withAnimation(fluid) { pomo.skip() } }
                        .transition(.blurReplace)
                }
                PlayButton(running: pomo.running) {
                    withAnimation(fluid) {
                        ui.editingTime = false
                        pomo.toggle()
                    }
                }
            }

            Group {
                if ui.snapshot {
                    Text(pomo.task.isEmpty ? "¿en qué estás?" : pomo.task)
                        .foregroundStyle(pomo.task.isEmpty ? pal.dim : pal.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $pomo.task, prompt: Text("¿en qué estás?").foregroundStyle(pal.dim))
                        .textFieldStyle(.plain)
                        .foregroundStyle(pal.fg)
                        .tint(pal.fg)
                        .focused($focused)
                        .onSubmit { focused = false; onEndEditing() }
                        .onExitCommand { focused = false; onEndEditing() }
                        .onChange(of: focused) { _, f in ui.editing = f }
                }
            }
            .font(geist(13, .medium))
            .frame(height: 22)

            // Everyone else's notch, in miniature: who they are and what they're on.
            if !ui.mates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ui.mates.prefix(3)) { m in
                        MateRow(mate: m, progress: pomo.progress, running: pomo.running, onBreak: pomo.phase.isBreak)
                    }
                    if ui.mates.count > 3 {
                        Text("y \(ui.mates.count - 3) más").font(geist(12, .medium)).foregroundStyle(pal.dim)
                            .padding(.leading, 12)
                    }
                }
                .padding(.top, 6)
                .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(width: ui.notch.width + 240)
    }
}

struct ToastView: View {
    @Environment(\.palette) private var pal
    let toast: Toast
    var notch: CGSize
    var onAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 12) {
                ToastIcon(kind: toast.icon)
                Text(toast.title).font(geist(14, .semibold))
                if let a = toast.action {
                    ActionButton(label: a, action: onAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .frame(minWidth: notch.width + 2 * LiveView.wing(1))
    }
}

// MARK: pieces

struct Ring: View {
    @Environment(\.palette) private var pal
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(pal.dim, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(pal.fg, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .frame(width: 16, height: 16)
    }
}

struct Dots: View {
    @Environment(\.palette) private var pal
    var done: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<Pomodoro.rounds, id: \.self) { i in
                Circle().fill(i < done ? pal.fg : pal.dim).frame(width: 5, height: 5)
            }
        }
    }
}

struct RoundButton: View {
    @Environment(\.palette) private var pal
    var symbol: String
    var active = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hover || active ? pal.fg : pal.dim)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(pal.fg.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PlayButton: View {
    @Environment(\.palette) private var pal
    var running: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: running ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(pal.bg)
                .contentTransition(.symbolEffect(.replace))
                .offset(x: running ? 0 : 1)
                .frame(width: 36, height: 36)
                .background(Circle().fill(pal.fg))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }
}

struct ActionButton: View {
    @Environment(\.palette) private var pal
    var label: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(geist(12, .semibold))
                .foregroundStyle(hover ? pal.fg : pal.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(pal.fg.opacity(hover ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ToastIcon: View {
    @Environment(\.palette) private var pal
    var kind: Toast.Icon
    @State private var drawn = snapshotMode
    @State private var popped = snapshotMode

    var body: some View {
        ZStack {
            Circle().fill(pal.fg)
            switch kind {
            case .success:
                CheckShape()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(pal.bg, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
                    .offset(y: 0.4)
            case .update:
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(pal.bg)
                    .offset(y: drawn ? 0 : -4)
                    .opacity(drawn ? 1 : 0)
            case .people:
                Image(systemName: "person.2.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(pal.bg)
                    .scaleEffect(drawn ? 1 : 0.4)
                    .opacity(drawn ? 1 : 0)
            case .info:
                VStack(spacing: 1.6) {
                    Capsule().fill(pal.bg).frame(width: 1.6, height: drawn ? 4.6 : 0)
                    Circle().fill(pal.bg).frame(width: 1.8, height: 1.8).scaleEffect(drawn ? 1 : 0)
                }
                .frame(height: 9, alignment: .top)
            }
        }
        .frame(width: 16, height: 16)
        .scaleEffect(popped ? 1 : 0.86)
        .rotationEffect(.degrees(popped ? 0 : -4))
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55).delay(0.14)) { popped = true }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.46).delay(0.16)) { drawn = true }
        }
    }
}

/// notch-toast check path `m3.45 8.15 2.75 2.7 6.35-6.2` in a 16-unit box.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        var p = Path()
        p.move(to: CGPoint(x: 3.45 * s, y: 8.15 * s))
        p.addLine(to: CGPoint(x: 6.2 * s, y: 10.85 * s))
        p.addLine(to: CGPoint(x: 12.55 * s, y: 4.65 * s))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Two people for a pair, three for three, three and a plus for bigger groups.
struct PeopleIcon: View {
    var count: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: count >= 3 ? "person.3.fill" : "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
            if count > 3 {
                Text("+").font(geist(11, .bold))
            }
        }
        .fixedSize()
    }
}

/// Someone else's notch, shrunk to one line inside yours.
struct MateRow: View {
    @Environment(\.palette) private var pal
    var mate: Mate
    var progress: Double
    var running: Bool
    var onBreak: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if onBreak {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 9, weight: .semibold))
                } else {
                    Ring(progress: progress).scaleEffect(0.8)
                }
            }
            .frame(width: 14)
            Text(mate.name).font(geist(12, .semibold)).foregroundStyle(running ? pal.fg : pal.dim)
            Text(mate.task.isEmpty ? "sin tarea" : mate.task)
                .font(geist(12, .medium)).foregroundStyle(pal.dim)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(pal.fg.opacity(0.08)))
    }
}

// MARK: chat

/// The little iMessage tail at the bottom corner on the sender's side. Drawn as its own fill:
/// merged into the bubble's path, opposite windings would punch a hole where they overlap.
struct BubbleTail: Shape {
    var mine: Bool

    func path(in r: CGRect) -> Path {
        let s: CGFloat = mine ? -1 : 1           // mirror for the right side
        let x0 = mine ? r.maxX : r.minX, y1 = r.maxY
        var p = Path()
        p.move(to: CGPoint(x: x0 + s * 7, y: y1 - 16))
        p.addCurve(to: CGPoint(x: x0 - s * 5, y: y1),
                   control1: CGPoint(x: x0 + s * 7, y: y1 - 6),
                   control2: CGPoint(x: x0 + s * 2, y: y1 - 1.5))
        p.addCurve(to: CGPoint(x: x0 + s * 14, y: y1 - 4),
                   control1: CGPoint(x: x0 + s * 3, y: y1 + 0.5),
                   control2: CGPoint(x: x0 + s * 9, y: y1 - 0.5))
        p.closeSubpath()
        return p
    }
}

struct Bubble: View {
    @Environment(\.palette) private var pal
    var message: ChatMessage
    var showName: Bool

    var body: some View {
        VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
            if showName && !message.mine {
                Text(message.from).font(geist(10.5, .semibold)).foregroundStyle(pal.dim).padding(.horizontal, 12)
            }
            Text(message.text)
                .font(geist(13, .medium))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous).fill(bubbleGreen)
                        BubbleTail(mine: message.mine).fill(bubbleGreen)
                    }
                }
                .frame(maxWidth: 240, alignment: message.mine ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }
}

/// Soft edges top and bottom: bubbles blur away as they scroll out or expire.
struct EdgeFade: ViewModifier {
    var top: CGFloat = 0.16
    var bottom: CGFloat = 0.12

    func body(content: Content) -> some View {
        content.mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: top),
            .init(color: .black, location: 1 - bottom),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

extension AnyTransition {
    /// A bubble rises in from below sharpening, and leaves blurring away.
    static let bubble = AnyTransition.asymmetric(
        insertion: .modifier(active: Reveal(hidden: true, y: 10, scale: 0.94, blur: 4),
                             identity: Reveal(hidden: false, y: 10, scale: 0.94, blur: 4)).animation(fluid),
        removal: .modifier(active: Reveal(hidden: true, y: -6, scale: 0.98, blur: 6),
                           identity: Reveal(hidden: false, y: -6, scale: 0.98, blur: 6)).animation(easeOut))
}

/// Messages that arrive while the chat is closed: they peek out under the camera and fade.
struct BubblesView: View {
    @Bindable var ui: NotchUI
    var onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ui.notch.height)
            VStack(spacing: 6) {
                ForEach(ui.bubbles) { m in
                    Bubble(message: m, showName: true).transition(.bubble)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .modifier(EdgeFade(top: 0.1, bottom: 0.08))
        }
        .frame(width: ui.notch.width + 150)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

struct ChatView: View {
    @Environment(\.palette) private var pal
    @Bindable var ui: NotchUI
    var onSend: (String) -> Void
    var onClose: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("chat").foregroundStyle(pal.dim)
                Spacer(minLength: ui.notch.width + 16)
                PeopleIcon(count: ui.people).foregroundStyle(pal.dim)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.dim)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .font(geist(12, .semibold))
            .frame(height: ui.notch.height)

            if ui.snapshot {
                // ImageRenderer can't draw a ScrollView; show the same list without it.
                list.frame(height: 132, alignment: .bottom).clipped().modifier(EdgeFade())
            } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) { list }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .frame(height: 132)
                .modifier(EdgeFade())
                .onChange(of: ui.messages.count) {
                    if let last = ui.messages.last { withAnimation(fluid) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            }

            HStack(spacing: 8) {
                Group {
                    if ui.snapshot {
                        Text(draft.isEmpty ? "mensaje…" : draft).foregroundStyle(pal.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: $draft, prompt: Text("mensaje…").foregroundStyle(pal.dim))
                            .textFieldStyle(.plain)
                            .foregroundStyle(pal.fg)
                            .tint(bubbleGreen)
                            .focused($focused)
                            .onSubmit(send)
                            .onExitCommand(perform: onClose)
                            .onChange(of: focused) { _, f in ui.editing = f }
                    }
                }
                .font(geist(13, .medium))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? pal.dim : bubbleGreen)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(height: 32)
            .background(Capsule().fill(pal.fg.opacity(0.08)))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(width: ui.notch.width + 240)
        .onAppear { if !ui.snapshot { focused = true } }
    }

    private var list: some View {
        VStack(spacing: 6) {
            if ui.messages.isEmpty {
                Text("escríbele al grupo").font(geist(12, .medium)).foregroundStyle(pal.dim)
                    .frame(maxWidth: .infinity).padding(.top, 48)
            }
            ForEach(ui.messages) { m in
                Bubble(message: m, showName: ui.people > 2).id(m.id).transition(.bubble)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(String(text.prefix(200)))
        draft = ""
    }
}
