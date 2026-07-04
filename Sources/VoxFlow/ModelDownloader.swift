import Foundation

/// Downloads missing models inside the app — no terminal needed.
/// Sequential queue with progress reporting; .part files + size checks so an
/// interrupted download is retried cleanly (same guarantees as setup.sh).
final class ModelDownloader: NSObject {
    struct Item {
        let url: URL
        let destination: URL
        let displayName: String
        let minSizeMB: Int
    }

    /// (status text e.g. "Downloading base.en… 42%", finished) on the main queue.
    var onProgress: ((String) -> Void)?
    var onFinished: ((_ errors: [String]) -> Void)?

    private(set) var isDownloading = false
    private var queue: [Item] = []
    private var errors: [String] = []
    private var currentTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Everything currently missing for dictation (selected whisper model) and,
    /// if cleanup is on, the LLM. Already-complete files are skipped.
    static func missingItems(settings: Settings) -> [Item] {
        var items: [Item] = []
        let model = settings.modelChoice
        if !fileComplete(at: settings.whisperModelPath, minSizeMB: model.minSizeMB) {
            items.append(Item(url: model.downloadURL,
                              destination: settings.whisperModelPath,
                              displayName: model.label,
                              minSizeMB: model.minSizeMB))
        }
        if settings.cleanupEnabled,
           !fileComplete(at: settings.llmModelPath, minSizeMB: Settings.llmMinSizeMB) {
            items.append(Item(url: Settings.llmDownloadURL,
                              destination: settings.llmModelPath,
                              displayName: "AI cleanup model",
                              minSizeMB: Settings.llmMinSizeMB))
        }
        return items
    }

    static func fileComplete(at url: URL, minSizeMB: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= Int64(minSizeMB) * 1_048_576
    }

    func start(items: [Item]) {
        guard !isDownloading, !items.isEmpty else { return }
        isDownloading = true
        errors = []
        queue = items
        startNext()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        queue = []
        finish()
    }

    private func startNext() {
        guard let item = queue.first else {
            finish()
            return
        }
        report("Downloading \(item.displayName)… 0%")
        try? FileManager.default.createDirectory(
            at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let task = session.downloadTask(with: item.url)
        currentTask = task
        task.resume()
    }

    private func finish() {
        isDownloading = false
        let errs = errors
        DispatchQueue.main.async { [weak self] in self?.onFinished?(errs) }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(text) }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let item = queue.first else { return }
        if totalBytesExpectedToWrite > 0 {
            let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
            report("Downloading \(item.displayName)… \(percent)%")
        } else {
            let mb = totalBytesWritten / 1_048_576
            report("Downloading \(item.displayName)… \(mb) MB")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let item = queue.first else { return }
        let fm = FileManager.default
        var failure: String?
        let http = downloadTask.response as? HTTPURLResponse
        if let status = http?.statusCode, status != 200 {
            failure = "\(item.displayName): server returned \(status)."
        } else if let size = (try? fm.attributesOfItem(atPath: location.path))?[.size] as? Int64,
                  size < Int64(item.minSizeMB) * 1_048_576 {
            failure = "\(item.displayName): download incomplete (\(size / 1_048_576) MB)."
        } else {
            do {
                if fm.fileExists(atPath: item.destination.path) {
                    try fm.removeItem(at: item.destination)
                }
                try fm.moveItem(at: location, to: item.destination)
            } catch {
                failure = "\(item.displayName): could not save file (\(error.localizedDescription))."
            }
        }
        if let failure = failure {
            errors.append(failure)
        }
        queue.removeFirst()
        currentTask = nil
        startNext()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return } // success handled above
        if (error as NSError).code == NSURLErrorCancelled { return }
        if let item = queue.first {
            errors.append("\(item.displayName): \(error.localizedDescription)")
            queue.removeFirst()
        }
        currentTask = nil
        startNext()
    }
}
