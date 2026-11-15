import Foundation
import Observation

enum Phase: String {
    case focus, short, long

    var label: String {
        switch self {
        case .focus: return "foco"
        case .short: return "descanso"
        case .long: return "descanso largo"
        }
    }

    var isBreak: Bool { self != .focus }
}

/// The timer. It only owns a `Timer` while running, and that timer fires once per
/// displayed second (aligned to the second boundary, with tolerance so macOS can
/// coalesce wakeups). Paused or idle = zero timers, zero wakeups.
@Observable
final class Pomodoro {
    var phase: Phase = .focus
    var remaining = 0
    var running = false
    var cycle = 0
    var task = ""
    var startedAt: Date?

    var focusMin = 25 { didSet { settingChanged("focusMin", focusMin) } }
    var shortMin = 5 { didSet { settingChanged("shortMin", shortMin) } }
    var longMin = 15 { didSet { settingChanged("longMin", longMin) } }

    @ObservationIgnored var onFinish: ((Phase) -> Void)?
    /// A focus session ran to the end: start, end, task, focus minutes.
    @ObservationIgnored var onFocusDone: ((Date, Date, String, Int) -> Void)?
    @ObservationIgnored let log: MarkdownLog
    /// 60 normally; 1 with POMO_FAST=1 so minutes become seconds for testing.
    @ObservationIgnored let unit: Double
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var pausedLeft: Double?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var restoring = true
    /// Fired after you change something yourself (not after a partner's change or a finish).
    @ObservationIgnored var onLocalChange: (() -> Void)?
    @ObservationIgnored private var applyingRemote = false

    static let rounds = 4

    init(log: MarkdownLog, unit: Double) {
        self.log = log
        self.unit = unit
        if d.object(forKey: "focusMin") != nil { focusMin = d.integer(forKey: "focusMin") }
        if d.object(forKey: "shortMin") != nil { shortMin = d.integer(forKey: "shortMin") }
        if d.object(forKey: "longMin") != nil { longMin = d.integer(forKey: "longMin") }
        phase = Phase(rawValue: d.string(forKey: "phase") ?? "") ?? .focus
        cycle = d.integer(forKey: "cycle")
        task = d.string(forKey: "task") ?? ""
        startedAt = d.object(forKey: "startedAt") as? Date
        endDate = d.object(forKey: "endDate") as? Date
        pausedLeft = d.object(forKey: "pausedLeft") as? Double
        pausedAt = d.object(forKey: "pausedAt") as? Date
        remaining = total
        restoring = false
    }

    /// Call once callbacks are wired: resumes a session that was running when the app quit.
    func restore() {
        if endDate != nil {
            running = true
            schedule()
        } else if let p = pausedLeft {
            remaining = Int(p.rounded(.up))
        }
    }

    func seconds(_ p: Phase) -> Int { Int(Double(minutes(p)) * unit) }

    var total: Int { seconds(phase) }
    var progress: Double { total > 0 ? 1 - Double(remaining) / Double(total) : 0 }
    var isIdle: Bool { startedAt == nil }

    private var left: Double {
        if let e = endDate { return max(0, e.timeIntervalSinceNow) }
        return pausedLeft ?? Double(total)
    }

    // MARK: controls

    func toggle() { running ? pause() : start() }

    func start() {
        guard !running else { return }
        let l = pausedLeft ?? Double(total)
        if startedAt == nil { startedAt = Date() }
        endDate = Date().addingTimeInterval(l)
        pausedLeft = nil
        pausedAt = nil
        running = true
        schedule()
        persist()
        changed()
    }

    func pause() {
        guard running else { return }
        pausedLeft = left
        pausedAt = Date()
        endDate = nil
        running = false
        stopTimer()
        remaining = Int(pausedLeft!.rounded(.up))
        persist()
        changed()
    }

    func reset() {
        logPartial()
        clearSession()
        remaining = total
        persist()
        changed()
    }

    func skip() {
        logPartial()
        clearSession()
        switch phase {
        case .focus: phase = .short
        case .short: phase = .focus
        case .long: cycle = 0; phase = .focus
        }
        remaining = total
        persist()
        changed()
    }

    static let steps = [1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 75, 90, 120]

    func minutes(_ p: Phase) -> Int {
        switch p {
        case .focus: return focusMin
        case .short: return shortMin
        case .long: return longMin
        }
    }

    /// One step up/down the duration ladder for the current phase. A session in
    /// progress keeps its elapsed time and moves its end by the same amount.
    func adjust(_ dir: Int) {
        let cur = minutes(phase)
        let next = dir > 0 ? (Self.steps.first { $0 > cur } ?? cur) : (Self.steps.last { $0 < cur } ?? cur)
        guard next != cur else { return }
        let delta = Double(next - cur) * unit
        if !isIdle {
            guard left + delta >= unit else { return }  // keep at least a minute left
            if let e = endDate { endDate = e.addingTimeInterval(delta) } else { pausedLeft = left + delta }
        }
        switch phase {
        case .focus: focusMin = next
        case .short: shortMin = next
        case .long: longMin = next
        }
        if !isIdle {
            remaining = Int(left.rounded(.up))
            if running { schedule() }
        }
        persist()
        changed()
    }

    func resetCycle() {
        cycle = 0
        persist()
        changed()
    }

    // MARK: together

    func snapshot() -> SyncState {
        SyncState(phase: phase.rawValue, running: running, left: left, inSession: startedAt != nil,
                  focusMin: focusMin, shortMin: shortMin, longMin: longMin, cycle: cycle)
    }

    /// Takes the partner's state as ours. A different session we had going is logged
    /// as cut first; one about to end on its own is let finish so it counts.
    func adopt(_ s: SyncState) {
        applyingRemote = true
        defer { applyingRemote = false }
        let p = Phase(rawValue: s.phase) ?? .focus
        if running, left < 2, p != phase { finish() }
        let same = startedAt != nil && s.inSession && p == phase
        if startedAt != nil && !same {
            logPartial()
            clearSession()
        }
        if focusMin != s.focusMin { focusMin = s.focusMin }
        if shortMin != s.shortMin { shortMin = s.shortMin }
        if longMin != s.longMin { longMin = s.longMin }
        phase = p
        cycle = s.cycle
        stopTimer()
        if s.inSession {
            if startedAt == nil { startedAt = Date().addingTimeInterval(-max(0, Double(total) - s.left)) }
            if s.running {
                endDate = Date().addingTimeInterval(s.left)
                pausedLeft = nil
                pausedAt = nil
                running = true
                schedule()
            } else {
                endDate = nil
                pausedLeft = s.left
                pausedAt = Date()
                running = false
                remaining = Int(s.left.rounded(.up))
            }
        } else {
            clearSession()
            remaining = total
        }
        persist()
    }

    private func changed() {
        if !applyingRemote && !restoring { onLocalChange?() }
    }

    /// Re-aligns after sleep/wake; finishes if the end passed while asleep.
    func resync() {
        if running { schedule() }
    }

    func saveTask() { d.set(task, forKey: "task") }

    // MARK: ticking

    private func schedule() {
        stopTimer()
        guard let e = endDate else { return }
        let l = e.timeIntervalSinceNow
        if l <= 0.05 { finish(); return }
        let shown = Int(l.rounded(.up))
        if shown != remaining { remaining = shown }
        // Fire just after the displayed value changes, then every second.
        var first = l - floor(l)
        if first < 0.02 { first += 1 }
        let t = Timer(fire: Date().addingTimeInterval(first + 0.01), interval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let e = endDate else { stopTimer(); return }
        let l = e.timeIntervalSinceNow
        if l <= 0.05 { finish(); return }
        let shown = Int(l.rounded(.up))
        if shown != remaining { remaining = shown }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func finish() {
        let p = phase
        let end = endDate ?? Date()
        let start = startedAt ?? end.addingTimeInterval(-Double(total))
        log.add(start: start, end: end, phase: p, seconds: total, cut: false, task: p == .focus ? task : "")
        if p == .focus { onFocusDone?(start, end, task, minutes(.focus)) }
        stopTimer()
        clearSession()
        if p == .focus {
            cycle += 1
            phase = cycle >= Self.rounds ? .long : .short
        } else {
            if p == .long { cycle = 0 }
            phase = .focus
        }
        remaining = total
        persist()
        onFinish?(p)
    }

    private func logPartial() {
        guard let s = startedAt else { return }
        let done = Int((Double(total) - left).rounded())
        guard Double(done) >= unit else { return }  // ignore < 1 min
        let end = running ? Date() : (pausedAt ?? Date())
        log.add(start: s, end: end, phase: phase, seconds: done, cut: true, task: phase == .focus ? task : "")
    }

    private func clearSession() {
        stopTimer()
        running = false
        endDate = nil
        pausedLeft = nil
        pausedAt = nil
        startedAt = nil
    }

    private func settingChanged(_ key: String, _ v: Int) {
        guard !restoring else { return }
        d.set(v, forKey: key)
        if isIdle { remaining = total }
        changed()
    }

    private func persist() {
        d.set(phase.rawValue, forKey: "phase")
        d.set(cycle, forKey: "cycle")
        d.set(task, forKey: "task")
        d.set(startedAt, forKey: "startedAt")
        d.set(endDate, forKey: "endDate")
        d.set(pausedLeft, forKey: "pausedLeft")
        d.set(pausedAt, forKey: "pausedAt")
    }
}

func clock(_ s: Int) -> String {
    let s = max(0, s)
    return String(format: "%d:%02d", s / 60, s % 60)
}
