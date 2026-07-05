import Foundation
import Darwin

enum ServerError: Error, LocalizedError {
    case binaryNotFound(String)
    case noFreePort
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "\(name) not found — please re-download VoxFlow.app from the Releases page."
        case .noFreePort:
            return "No free local port found for the inference server."
        case .failedToStart(let name):
            return "\(name) failed to start. Re-download VoxFlow.app, or check the model file."
        }
    }
}

/// Spawns and supervises whisper-server and llama-server as child processes.
/// Children are killed on quit and on model switch (SPEC R7); an unexpected
/// crash is relaunched once, then surfaced as an error (SPEC edge cases).
/// Child PIDs are recorded to disk so a crashed/force-quit VoxFlow can clean
/// up stale children on next launch.
final class ServerManager {
    static let whisperBasePort = 8321
    static let llamaBasePort = 8322

    /// Leave a couple of cores for the UI and the foreground app.
    static var inferenceThreads: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    private(set) var whisperPort: Int?
    private(set) var llamaPort: Int?

    private var whisperProcess: Process?
    private var llamaProcess: Process?
    private var whisperRelaunchedOnce = false
    private var llamaRelaunchedOnce = false

    /// Called on the main queue when a server dies twice in a row.
    var onServerFailure: ((String) -> Void)?

    // MARK: - Public lifecycle

    func startWhisper(modelPath: String, language: String) throws {
        stopWhisper()
        whisperRelaunchedOnce = false
        try launchWhisper(modelPath: modelPath, language: language)
    }

    func startLlama(modelPath: String) throws {
        stopLlama()
        llamaRelaunchedOnce = false
        try launchLlama(modelPath: modelPath)
    }

    func stopWhisper() {
        // Clear the reference FIRST: the termination handler is identity-checked,
        // so a deliberate terminate() is ignored by the crash-relaunch logic.
        let process = whisperProcess
        whisperProcess = nil
        whisperPort = nil
        process?.terminate()
        recordChildren()
    }

    func stopLlama() {
        let process = llamaProcess
        llamaProcess = nil
        llamaPort = nil
        process?.terminate()
        recordChildren()
    }

    func stopAll() {
        stopWhisper()
        stopLlama()
    }

    var whisperRunning: Bool {
        guard let p = whisperProcess else { return false }
        return p.isRunning
    }

    var llamaRunning: Bool {
        guard let p = llamaProcess else { return false }
        return p.isRunning
    }

    /// Polls until the given port accepts TCP connections (server finished loading its model).
    func waitUntilReady(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ServerManager.canConnect(port: port) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    // MARK: - Launch helpers

    private func launchWhisper(modelPath: String, language: String) throws {
        guard let bin = ServerManager.brewBinary("whisper-server") else {
            throw ServerError.binaryNotFound("whisper-server")
        }
        guard let port = freePort(from: ServerManager.whisperBasePort) else {
            throw ServerError.noFreePort
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-l", language, // belt & braces: also sent per-request
            "-t", String(ServerManager.inferenceThreads),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, self.whisperProcess === proc else { return }
                self.whisperDied(modelPath: modelPath, language: language)
            }
        }
        do {
            try process.run()
        } catch {
            throw ServerError.failedToStart("whisper-server")
        }
        whisperProcess = process
        whisperPort = port
        recordChildren()
    }

    private func launchLlama(modelPath: String) throws {
        guard let bin = ServerManager.brewBinary("llama-server") else {
            throw ServerError.binaryNotFound("llama-server")
        }
        guard let port = freePort(from: ServerManager.llamaBasePort) else {
            throw ServerError.noFreePort
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "4096",
            "-t", String(ServerManager.inferenceThreads),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, self.llamaProcess === proc else { return }
                self.llamaDied(modelPath: modelPath)
            }
        }
        do {
            try process.run()
        } catch {
            throw ServerError.failedToStart("llama-server")
        }
        llamaProcess = process
        llamaPort = port
        recordChildren()
    }

    private func whisperDied(modelPath: String, language: String) {
        whisperProcess = nil
        whisperPort = nil
        recordChildren()
        if !whisperRelaunchedOnce {
            whisperRelaunchedOnce = true
            try? launchWhisper(modelPath: modelPath, language: language)
            if whisperProcess != nil { return }
        }
        onServerFailure?("Transcription server stopped unexpectedly.")
    }

    private func llamaDied(modelPath: String) {
        llamaProcess = nil
        llamaPort = nil
        recordChildren()
        if !llamaRelaunchedOnce {
            llamaRelaunchedOnce = true
            try? launchLlama(modelPath: modelPath)
            if llamaProcess != nil { return }
        }
        onServerFailure?("AI-cleanup server stopped unexpectedly. Cleanup disabled until restart.")
    }

    /// First free port in [base, base+10), skipping ports already assigned to
    /// our other child (which may not have bound its socket yet — TOCTOU guard).
    private func freePort(from base: Int) -> Int? {
        let reserved = Set([whisperPort, llamaPort].compactMap { $0 })
        for port in base..<(base + 10)
        where !reserved.contains(port) && ServerManager.isPortFree(port) {
            return port
        }
        return nil
    }

    // MARK: - Stale-child cleanup (crash safety, SPEC R7)

    private static var pidFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/children.pids")
    }

    /// Persist "<pid> <binary-name>" for each live child.
    private func recordChildren() {
        var lines: [String] = []
        if let p = whisperProcess, p.isRunning {
            lines.append("\(p.processIdentifier) whisper-server")
        }
        if let p = llamaProcess, p.isRunning {
            lines.append("\(p.processIdentifier) llama-server")
        }
        let url = ServerManager.pidFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if lines.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Kill children left behind by a previous crashed/force-quit VoxFlow.
    /// Only kills a PID if it still runs the exact binary we recorded.
    static func killStaleChildren() {
        let url = pidFileURL
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let expectedName = String(parts[1])
            if let command = commandName(pid: pid),
               command == expectedName || command.hasSuffix("/" + expectedName) {
                kill(pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func commandName(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    // MARK: - Static utilities

    /// Locates a server binary. Preference order:
    /// 1. Bundled inside VoxFlow.app/Contents/Resources/bin (downloadable-app builds)
    /// 2. Homebrew on Apple Silicon (/opt/homebrew) or Intel (/usr/local)
    static func brewBinary(_ name: String) -> String? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("bin/\(name)").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
