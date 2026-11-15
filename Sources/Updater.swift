import AppKit
import CryptoKit
import Foundation

/// Self-update from GitHub Releases. Looks once ~20 s after launch and then once a day
/// (a coalescable timer, no polling). An update is only installed if its zip carries
/// an Ed25519 signature from the maintainer's key (UpdateKey), so a tampered download
/// or a hijacked release can't replace the app.
///
/// Downloads made here aren't quarantined, so only the very first install meets Gatekeeper.
final class Updater {
    static let repo = "ignaciobernardo/notch-pomodoro"

    struct Release {
        let version: String
        let zip: URL
        let sig: URL
    }

    private(set) var available: Release?
    private(set) var installing = false
    var onAvailable: ((Release) -> Void)?
    private var timer: Timer?

    var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `done` gets whether a newer version exists (nil when GitHub couldn't be reached).
    func check(done: ((Bool?) -> Void)? = nil) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession(configuration: .ephemeral).dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                DispatchQueue.main.async { done?(nil) }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            func asset(_ name: String) -> URL? {
                (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
            }
            DispatchQueue.main.async {
                guard Self.isNewer(version, than: self.current),
                      let zip = asset("Pomodoro.zip"), let sig = asset("Pomodoro.zip.sig") else {
                    done?(false)
                    return
                }
                let r = Release(version: version, zip: zip, sig: sig)
                let isNew = self.available?.version != version
                self.available = r
                if isNew { self.onAvailable?(r) }
                done?(true)
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func verify(_ data: Data, signature sigText: String, publicKey: String = UpdateKey.publicKey) -> Bool {
        guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Download, verify, swap the app bundle in place, relaunch. Failures leave the current app untouched.
    func install(failed: @escaping (String) -> Void) {
        guard let r = available, !installing else { return }
        installing = true
        let target = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier
        Task.detached {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("pomodoro-update-\(UUID().uuidString)")
            do {
                let session = URLSession(configuration: .ephemeral)
                let (zipData, _) = try await session.data(from: r.zip)
                let (sigData, _) = try await session.data(from: r.sig)
                guard Self.verify(zipData, signature: String(decoding: sigData, as: UTF8.self)) else {
                    throw UpdateError("la firma no coincide")
                }
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zipURL = tmp.appendingPathComponent("Pomodoro.zip")
                try zipData.write(to: zipURL)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, tmp.path])
                let fresh = tmp.appendingPathComponent("Pomodoro.app")
                guard Bundle(url: fresh)?.bundleIdentifier == bundleID else { throw UpdateError("el paquete no es Pomodoro") }
                let old = tmp.appendingPathComponent("previous.app")
                try fm.moveItem(at: target, to: old)
                do {
                    try fm.moveItem(at: fresh, to: target)
                } catch {
                    try? fm.moveItem(at: old, to: target)
                    throw error
                }
                await MainActor.run { Self.relaunch(target) }
            } catch {
                try? fm.removeItem(at: tmp)
                let msg = (error as? UpdateError)?.message ?? "no se pudo descargar"
                await MainActor.run {
                    self.installing = false
                    failed(msg)
                }
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("no se pudo descomprimir") }
    }

    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: Error {
    let message: String
    init(_ m: String) { message = m }
}
