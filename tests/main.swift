// swiftc -O -swift-version 5 Sources/Pomodoro.swift Sources/MarkdownLog.swift tests/main.swift -o build/logic-test
// Runs real timers with minutes-as-seconds and checks the Markdown log.
import CryptoKit
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "pomo-test.md"
try? FileManager.default.removeItem(atPath: path)
for k in ["phase", "cycle", "task", "startedAt", "endDate", "pausedLeft", "pausedAt", "focusMin", "shortMin", "longMin"] {
    UserDefaults.standard.removeObject(forKey: k)
}
let p = Pomodoro(log: MarkdownLog(url: URL(fileURLWithPath: path)), unit: 1)
p.focusMin = 2; p.shortMin = 1; p.longMin = 1
var finished: [Phase] = []
p.onFinish = { finished.append($0) }
func run(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func check(_ c: Bool, _ m: String) { print(c ? "ok  " : "FAIL", m); if !c { exit(1) } }

p.task = "landing | web"
p.start(); check(p.running && p.remaining == 2, "start focus 2s")
run(1.2); check(p.remaining == 1, "ticks to 1 (got \(p.remaining))")
run(1.0); check(finished == [.focus] && p.phase == .short && p.cycle == 1 && !p.running, "focus completes → short break")
p.start(); run(1.3); check(finished.last == .short && p.phase == .focus, "break completes → focus")
p.start(); run(0.5); p.pause(); let left = p.remaining
run(1.0); check(p.remaining == left && !p.running, "pause holds time")
p.start(); run(1.8); check(finished.count == 3 && p.cycle == 2, "resume and complete after pause")
p.start(); run(0.4); p.skip(); check(p.phase == .focus && !p.running, "skip break")
p.focusMin = 5; p.start(); run(2.2); p.reset(); check(p.isIdle && p.remaining == 5, "reset mid-focus")
p.start(); run(0.3); p.reset(); check(p.isIdle, "reset after <1 unit (not logged)")

let md = try! String(contentsOfFile: path, encoding: .utf8)
print("---\n" + md + "---")
let rows = md.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.contains("inicio") && !$0.contains("---") }
check(rows.count == 4, "4 rows logged: 2 focus, 1 break, 1 cut (got \(rows.count))")
check(rows.filter { $0.contains("| foco |") }.count == 2, "2 full focus rows")
check(md.contains("foco cortado"), "cut focus logged")
check(md.contains("landing / web"), "pipe escaped in task")
check(md.contains("total foco: 0 min · 2 pomodoros"), "total line")
check(rows[1].hasSuffix("| descanso | 0:01 |  |"), "break row has no task")
// time editing
p.reset(); while p.phase != .focus { p.skip() }
p.focusMin = 25; p.adjust(1); check(p.focusMin == 30 && p.remaining == 30, "idle + → 30")
p.adjust(-1); p.adjust(-1); check(p.focusMin == 20 && p.remaining == 20, "idle − − → 20")
p.start(); run(1.2); p.adjust(1); check(p.focusMin == 25 && p.remaining == 24, "running + keeps elapsed (got \(p.remaining))")
p.pause(); p.adjust(-1); check(p.focusMin == 20 && p.remaining == 19, "paused − keeps elapsed (got \(p.remaining))")
p.reset(); p.focusMin = 3; p.start(); run(1.2); p.pause(); p.adjust(-1); check(p.focusMin == 3 && p.remaining == 2, "can't cut below 1 left")
p.reset()
// juntos: two notches adopting each other's snapshots
let pathB = path + ".b.md"
try? FileManager.default.removeItem(atPath: pathB)
let a = p
a.reset(); while a.phase != .focus { a.skip() }
a.focusMin = 3; a.shortMin = 1
let b = Pomodoro(log: MarkdownLog(url: URL(fileURLWithPath: pathB)), unit: 1)
a.onLocalChange = { b.adopt(a.snapshot()) }
b.onLocalChange = { a.adopt(b.snapshot()) }
b.adopt(a.snapshot())
check(b.focusMin == 3 && b.phase == .focus && b.isIdle, "join adopts durations and phase")
a.start(); check(b.running && abs(b.remaining - a.remaining) <= 1, "start syncs")
run(1.1); b.pause(); check(!a.running && a.remaining == b.remaining, "pause from the other side syncs")
var bFinished = 0
b.onFinish = { _ in bFinished += 1 }
a.start(); run(2.3)
check(a.phase == .short && b.phase == .short && bFinished == 1, "both finish on their own")
a.start(); check(b.running && b.phase == .short, "break started on one side starts on both")
b.skip(); check(a.phase == .focus && a.isIdle && !a.running, "skip from the other side syncs")
a.adjust(1); check(b.focusMin == a.focusMin, "duration change syncs")
let bRows = (try? String(contentsOfFile: pathB, encoding: .utf8))?.split(separator: "\n").filter { $0.contains("| foco |") }.count ?? 0
check(bRows == 1, "b logged its own full focus once (got \(bRows))")
a.onLocalChange = nil; b.onLocalChange = nil; a.reset(); b.reset()
// updater: version order and signature check
check(Updater.isNewer("1.0.1", than: "1.0.0") && Updater.isNewer("1.10", than: "1.9") && !Updater.isNewer("1.0", than: "1.0.0"), "version order")
let tk = Curve25519.Signing.PrivateKey()
let blob = Data("pomodoro".utf8)
let goodSig = try! tk.signature(for: blob).base64EncodedString()
let pub = tk.publicKey.rawRepresentation.base64EncodedString()
check(Updater.verify(blob, signature: goodSig, publicKey: pub), "valid signature accepted")
check(!Updater.verify(Data("tampered".utf8), signature: goodSig, publicKey: pub), "tampered zip refused")
check(!Updater.verify(blob, signature: goodSig), "signature from another key refused")
print("all good")
