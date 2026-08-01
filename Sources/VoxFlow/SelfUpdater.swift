import AppKit
import Foundation

/// One-click in-app updates: downloads the latest release zip, swaps the app
/// bundle in place, and relaunches. If anything fails, the old version is
/// restored and the Releases page opens as a fallback. Rollbacks are just as
/// easy: every previous version stays downloadable on the Releases page
/// (documented in CHANGELOG.md).
final class SelfUpdater {
    static let assetURL = URL(string:
        "https://github.com/victorsondergaard/voxflow/releases/latest/download/VoxFlow.app.zip")!

    /// Menu status text while updating (nil when idle), on the main queue.
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isUpdating = false

    func installLatest() {
        guard !isUpdating else { return }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        // Self-swap only works for a real installed copy we can write next to;
        // otherwise fall back to the manual download page.
        guard appPath.hasSuffix("VoxFlow.app"),
              FileManager.default.isWritableFile(atPath: parent) else {
            NSWorkspace.shared.open(UpdateChecker.releasesPage)
            return
        }
        isUpdating = true
        onStatus?("Downloading update…")
        let task = URLSession.shared.downloadTask(with: SelfUpdater.assetURL) { [weak self] tmp, _, error in
            DispatchQueue.main.async {
                self?.finishDownload(tmp: tmp, error: error, appPath: appPath)
            }
        }
        task.resume()
    }

    private func finishDownload(tmp: URL?, error: Error?, appPath: String) {
        guard let tmp = tmp, error == nil else {
            fail("Update download failed: \(error?.localizedDescription ?? "unknown error")")
            return
        }
        onStatus?("Installing update…")
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("VoxFlowUpdate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipPath = workDir.appendingPathComponent("VoxFlow.app.zip")
            try fm.moveItem(at: tmp, to: zipPath)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zipPath.path, workDir.path]
            try unzip.run()
            unzip.waitUntilExit()
            let newApp = workDir.appendingPathComponent("VoxFlow.app")
            guard unzip.terminationStatus == 0, fm.fileExists(atPath: newApp.path) else {
                fail("Could not unpack the update.")
                return
            }

            // Swap: move the running copy aside, move the new one in, and if
            // that second step fails put the old one straight back.
            let oldAside = workDir.appendingPathComponent("VoxFlow-previous.app")
            try fm.moveItem(atPath: appPath, toPath: oldAside.path)
            do {
                try fm.moveItem(atPath: newApp.path, toPath: appPath)
            } catch {
                try? fm.moveItem(atPath: oldAside.path, toPath: appPath)
                throw error
            }

            isUpdating = false
            onStatus?(nil)
            relaunch(appPath: appPath)
        } catch {
            fail("Update failed: \(error.localizedDescription)")
        }
    }

    /// Detached helper reopens the (new) app right after we quit.
    private func relaunch(appPath: String) {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appPath)\""]
        try? script.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private func fail(_ message: String) {
        isUpdating = false
        onStatus?(nil)
        onError?(message)
    }
}
