import AppKit
import SwiftUI

/// Debug only (POMO_SNAPSHOT=dir): walks through the states and writes a PNG of each,
/// rendered by SwiftUI itself, so the design can be checked without screen capture.
/// The hardware notch is drawn in red so nothing important ends up behind the camera.
var snapshotMode = false

@MainActor
enum Snapshot {
    static func run(app: AppDelegate, dir: String) {
        snapshotMode = true
        app.ui.snapshot = true
        let pomo = app.pomo
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let steps: [(String, () -> Void)] = [
            ("1-idle", { pomo.reset() }),
            ("2-live-running", { pomo.start() }),
            ("3-expanded-running", { app.setExpanded(true) }),
            ("4-expanded-task-paused", { pomo.task = "landing nueva"; pomo.pause() }),
            ("5-toast-focus-done", {
                app.show(Toast(icon: .success, title: "foco listo · 25 min", action: "descansar"), seconds: 60)
            }),
            ("6-toast-break-done", {
                app.show(Toast(icon: .info, title: "se acabó el descanso", action: "enfocarse"), seconds: 60)
            }),
            ("7-live-break", {
                app.dismissToast(); app.setExpanded(false); pomo.task = ""; pomo.skip(); pomo.start()
            }),
            ("8-expanded", { pomo.reset(); app.setExpanded(true) }),
            ("9-edit-time", { app.ui.editingTime = true; pomo.adjust(1) }),
            ("10-group-live", {
                app.ui.editingTime = false; pomo.adjust(-1); app.setExpanded(false)
                app.ui.mates = [Mate(id: "1", name: "juan", task: "tesis cap. 3"), Mate(id: "2", name: "ana", task: ""),
                                Mate(id: "3", name: "sofi", task: "informe final")]
                pomo.start()
            }),
            ("11-group-expanded", { app.setExpanded(true); pomo.task = "landing nueva" }),
            ("12-pair-live", { app.setExpanded(false); app.ui.mates = [Mate(id: "1", name: "juan", task: "tesis")] }),
            ("13-trio-live", { app.ui.mates.append(Mate(id: "2", name: "ana", task: "")) }),
        ]

        var i = 0
        func next() {
            guard i < steps.count else {
                exit(0)
            }
            let (name, step) = steps[i]
            i += 1
            step()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                render(app: app, name: name, dir: dir)
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }

    static func render(app: AppDelegate, name: String, dir: String) {
        let n = app.ui.notch
        let view = ZStack(alignment: .top) {
            Color(white: 0.9)
            NotchView(ui: app.ui, pomo: app.pomo, onToastAction: {}, onEndEditing: {}, onTogether: {})
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .stroke(Color.red.opacity(0.8), lineWidth: 1)
                .frame(width: n.width, height: n.height)
        }
        .frame(width: 560, height: 170)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed", name); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", name, "size", app.ui.size, "window", app.panel.frame)
    }
}
