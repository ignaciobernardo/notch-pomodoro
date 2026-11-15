import EventKit
import Foundation

/// Adds each finished focus session to a calendar through EventKit, so it lands
/// in whatever account macOS Calendar syncs (Google, iCloud, Exchange...).
///
/// Costs nothing while idle: the event store is created only at the moment a
/// session ends (or the menu lists calendars) and released right after.
final class CalendarSync {
    private let d = UserDefaults.standard

    var enabled: Bool {
        get { d.bool(forKey: "calendarOn") && authorized }
        set { d.set(newValue, forKey: "calendarOn") }
    }

    var calendarID: String? {
        get { d.string(forKey: "calendarID") }
        set { d.set(newValue, forKey: "calendarID") }
    }

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var denied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted || s == .writeOnly
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        EKEventStore().requestFullAccessToEvents { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Writable calendars grouped by account, for the menu.
    func calendars() -> [(account: String, id: String, title: String)] {
        guard authorized else { return [] }
        let s = EKEventStore()
        return s.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { (account: $0.source.title, id: $0.calendarIdentifier, title: $0.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func currentTitle() -> String? {
        guard authorized else { return nil }
        let s = EKEventStore()
        let cal = calendarID.flatMap { s.calendar(withIdentifier: $0) } ?? s.defaultCalendarForNewEvents
        return cal?.title
    }

    func addFocus(start: Date, end: Date, task: String, minutes: Int) {
        guard enabled else { return }
        let s = EKEventStore()
        guard let cal = calendarID.flatMap({ s.calendar(withIdentifier: $0) }) ?? s.defaultCalendarForNewEvents else { return }
        let e = EKEvent(eventStore: s)
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        e.title = t.isEmpty ? "pomodoro" : "pomodoro · \(t)"
        e.startDate = start
        e.endDate = end
        e.notes = "\(minutes) min de foco"
        e.calendar = cal
        e.availability = .busy
        do {
            try s.save(e, span: .thisEvent, commit: true)
        } catch {
            NSLog("pomodoro: no pude agregar al calendario: %@", String(describing: error))
        }
    }
}
