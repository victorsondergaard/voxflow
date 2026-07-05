import AppKit

/// Checks GitHub Releases for a newer VoxFlow and surfaces it in the menu.
/// Runs at launch and every 24 h. The only data sent is a normal HTTPS
/// request to api.github.com — no identifiers, nothing about you.
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/victorsondergaard/voxflow/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/victorsondergaard/voxflow/releases/latest")!

    /// Called on the main queue with the newer tag, e.g. "v1.0.12".
    var onUpdateAvailable: ((String) -> Void)?
    private var timer: Timer?

    func start() {
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check() {
        var request = URLRequest(url: UpdateChecker.api)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else { return }
            if UpdateChecker.isNewer(tag: tag, than: UpdateChecker.currentVersion) {
                DispatchQueue.main.async { self?.onUpdateAvailable?(tag) }
            }
        }.resume()
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric component-wise compare of "v1.0.12"-style versions.
    static func isNewer(tag: String, than current: String) -> Bool {
        func parts(_ string: String) -> [Int] {
            string.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
