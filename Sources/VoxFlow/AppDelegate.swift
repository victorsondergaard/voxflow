import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuDelegate {
    private let settings = Settings.shared
    private var statusController: StatusItemController!
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let servers = ServerManager()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private let inserter = TextInserter()
    private let downloader = ModelDownloader()
    private let speech = AVSpeechSynthesizer()
    private let hud = HUDController()
    private let updater = UpdateChecker()

    private var state: DictationState = .idle
    private var downloadStatusText: String?
    private var pressDate: Date?
    private var pressCategory: AppCategory = .general
    private var recordingIconWork: DispatchWorkItem?
    private var trustPollTimer: Timer?
    private var errorMessage: String?
    private var hasTranscribedOnce = false
    private var updateAvailableTag: String?
    private(set) var lastTranscriptValue: String?

    private static let minHoldSeconds: TimeInterval = 0.15 // SPEC R5

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        statusController.delegate = self

        servers.onServerFailure = { [weak self] message in
            self?.errorMessage = message
        }

        hotkeyMonitor.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeyMonitor.onRelease = { [weak self] in self?.hotkeyReleased() }

        recorder.onLevel = { [weak self] level in
            self?.hud.setLevel(level)
        }

        downloader.onProgress = { [weak self] text in
            self?.downloadStatusText = text
        }
        downloader.onFinished = { [weak self] errors in
            guard let self = self else { return }
            self.downloadStatusText = nil
            if errors.isEmpty {
                self.startServersIfPossible()
            } else {
                self.errorMessage = errors.joined(separator: " ")
                self.showAlert(title: "Model download failed",
                               text: errors.joined(separator: "\n")
                                    + "\n\nCheck your internet connection, then choose “Download models…” from the menu again.")
            }
        }

        updater.onUpdateAvailable = { [weak self] tag in
            self?.updateAvailableTag = tag
        }
        updater.start()

        ensureAccessibilityPermission()
        startHotkeyMonitoring()
        ServerManager.killStaleChildren() // from a previous crash/force-quit (SPEC R7)
        startServersIfPossible()

        // First-run: offer to download missing models right away (no terminal).
        let missing = ModelDownloader.missingItems(settings: settings)
        if !missing.isEmpty && ServerManager.brewBinary("whisper-server") != nil {
            startModelDownload()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor.stop()
        servers.stopAll() // no orphan child processes (SPEC R7)
    }

    // MARK: - Permissions

    private func ensureAccessibilityPermission() {
        // The system prompt both explains and registers the app in the
        // Accessibility list; we surface a menu banner instead of stacking
        // a second modal on top of it.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            errorMessage = "Grant Accessibility access (System Settings → Privacy & Security → Accessibility) — VoxFlow will notice automatically."
            startTrustPolling()
        }
    }

    /// No relaunch needed: poll until the user flips the Accessibility toggle,
    /// then (re)create the event tap and clear the banner. Also heals the case
    /// where an app update invalidated a previous grant (ad-hoc signatures
    /// change every build, so macOS sees each update as a new app).
    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, AXIsProcessTrusted() else { return }
            self.trustPollTimer?.invalidate()
            self.trustPollTimer = nil
            self.hotkeyMonitor.stop()
            if self.hotkeyMonitor.start() {
                self.errorMessage = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func startHotkeyMonitoring() {
        if !hotkeyMonitor.start() {
            errorMessage = "Hotkey unavailable — grant Accessibility access; VoxFlow will notice automatically."
            startTrustPolling()
        }
    }

    private func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Server lifecycle

    private func startServersIfPossible() {
        if settings.whisperProblems().isEmpty {
            do {
                try servers.startWhisper(modelPath: settings.whisperModelPath.path,
                                         language: settings.modelChoice.language)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if settings.cleanupEnabled && settings.cleanupProblems().isEmpty {
            startLlamaIfPossible()
        }
    }

    private func startLlamaIfPossible() {
        guard FileManager.default.fileExists(atPath: settings.llmModelPath.path) else { return }
        do {
            try servers.startLlama(modelPath: settings.llmModelPath.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dictation flow

    private func hotkeyPressed() {
        guard state == .idle else { return }
        // Only whisper is required to dictate; missing cleanup pieces must never
        // block dictation — cleanup just falls back to raw text (SPEC R11 spirit).
        guard settings.whisperProblems().isEmpty else {
            showSetupHelp()
            return
        }
        // Category captured at press time — where dictation started (SPEC edge cases).
        pressCategory = ContextDetector.currentCategory()
        pressDate = Date()

        requestMicAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.pressDate = nil
                self.showAlert(
                    title: "Microphone permission needed",
                    text: "System Settings → Privacy & Security → Microphone → enable VoxFlow."
                )
                return
            }
            // Abort if the key was already released during the permission round-trip.
            guard self.pressDate != nil else { return }
            do {
                // Capture starts immediately so no speech is lost; audio from
                // holds shorter than 150 ms is discarded on release (SPEC R5).
                try self.recorder.start()
                self.state = .recording
                self.hud.showListening() // instant feedback: the pill appears as you speak
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .recording else { return }
                    self.statusController.setState(.recording)
                }
                self.recordingIconWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.minHoldSeconds, execute: work)
            } catch {
                self.pressDate = nil
                self.errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    private func hotkeyReleased() {
        recordingIconWork?.cancel()
        recordingIconWork = nil
        guard let pressed = pressDate else { return }
        pressDate = nil

        let heldFor = Date().timeIntervalSince(pressed)
        let wav = recorder.stop()

        // Accidental tap: discard entirely (SPEC R5).
        guard heldFor >= AppDelegate.minHoldSeconds, !wav.isEmpty else {
            state = .idle
            statusController.setState(.idle)
            hud.hide()
            return
        }

        guard servers.whisperPort != nil, servers.whisperRunning else {
            state = .idle
            statusController.setState(.idle)
            hud.hide()
            errorMessage = "Transcription server is not running."
            showAlert(title: "VoxFlow",
                      text: "The transcription server is not running. Open the VoxFlow menu bar icon for details.")
            return
        }

        state = .processing
        statusController.setState(.processing)
        hud.showProcessing() // rolling-wave loading animation while transcribing
        let language = settings.modelChoice.language
        let category = pressCategory
        // First dictation may wait on model load; afterwards the server is warm.
        let readyTimeout: TimeInterval = hasTranscribedOnce ? 25 : 90

        Task { @MainActor in
            defer {
                self.state = .idle
                self.statusController.setState(.idle)
                self.hud.hide()
            }
            guard let port = self.servers.whisperPort else { return }
            _ = await self.servers.waitUntilReady(port: port, timeout: readyTimeout)
            // The server may have crash-relaunched on a different port meanwhile.
            let livePort = self.servers.whisperPort ?? port
            let raw: String
            do {
                raw = try await self.transcriber.transcribe(wav: wav, port: livePort, language: language)
            } catch {
                self.errorMessage = error.localizedDescription
                self.showAlert(title: "Transcription failed", text: error.localizedDescription)
                return
            }
            self.hasTranscribedOnce = true
            guard !raw.isEmpty else {
                // Silence: insert nothing, keep last transcript (SPEC edge cases).
                self.statusController.flashIdle()
                return
            }

            var final = raw
            if self.settings.cleanupEnabled,
               let llamaPort = self.servers.llamaPort, self.servers.llamaRunning {
                // Failure or >20 s timeout falls back to raw (SPEC R11).
                if let cleaned = await self.cleaner.clean(raw, category: category, port: llamaPort,
                                                          assist: self.settings.assistModeEnabled) {
                    final = cleaned
                }
            }

            self.lastTranscriptValue = final
            self.errorMessage = nil
            self.inserter.insert(final)
            if self.settings.readBackEnabled {
                self.speak(final)
            }
        }
    }

    private func speak(_ text: String) {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speech.speak(utterance)
    }

    // MARK: - StatusMenuDelegate

    var cleanupEnabled: Bool { settings.cleanupEnabled }
    var assistEnabled: Bool { settings.assistModeEnabled }
    var readBackEnabled: Bool { settings.readBackEnabled }
    var downloadStatus: String? { downloadStatusText }
    var modelsAreMissing: Bool {
        !downloader.isDownloading && !ModelDownloader.missingItems(settings: settings).isEmpty
    }
    var currentModel: ModelChoice { settings.modelChoice }
    var currentHotkey: Hotkey { settings.hotkey }
    var lastTranscript: String? { lastTranscriptValue }
    var setupProblems: [String] { settings.setupProblems() }
    var currentError: String? { errorMessage }
    var updateAvailable: String? { updateAvailableTag }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleCleanup() {
        settings.cleanupEnabled.toggle()
        if settings.cleanupEnabled {
            if settings.cleanupProblems().isEmpty {
                startLlamaIfPossible()
            } else if ServerManager.brewBinary("llama-server") != nil {
                startModelDownload() // just the model is missing — fetch it in-app
            } else {
                showSetupHelp() // dictation keeps working; cleanup falls back to raw
            }
        } else {
            servers.stopLlama() // cleanup OFF → llama-server not running (SPEC R10)
        }
    }

    func toggleAssist() {
        settings.assistModeEnabled.toggle()
        // Assist works through cleanup; switch cleanup on for the user if needed.
        if settings.assistModeEnabled && !settings.cleanupEnabled {
            toggleCleanup()
        }
    }

    func toggleReadBack() {
        settings.readBackEnabled.toggle()
    }

    func speakLastTranscript() {
        guard let transcript = lastTranscriptValue else { return }
        speak(transcript)
    }

    func startModelDownload() {
        guard !downloader.isDownloading else { return }
        let items = ModelDownloader.missingItems(settings: settings)
        guard !items.isEmpty else { return }
        downloadStatusText = "Starting download…"
        downloader.start(items: items)
    }

    func selectModel(_ model: ModelChoice) {
        guard model != settings.modelChoice else { return }
        settings.modelChoice = model
        errorMessage = nil
        hasTranscribedOnce = false // new model needs a warm-up load
        guard FileManager.default.fileExists(atPath: settings.whisperModelPath.path) else {
            servers.stopWhisper()
            startModelDownload() // fetch the newly selected model in-app
            return
        }
        do {
            // startWhisper kills the old child first (SPEC R7).
            try servers.startWhisper(modelPath: settings.whisperModelPath.path,
                                     language: model.language)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectHotkey(_ hotkey: Hotkey) {
        settings.hotkey = hotkey // monitor reads Settings on every event; no restart needed
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Launch at Login",
                      text: "Could not change the setting: \(error.localizedDescription)\n\nNote: this only works when running the built VoxFlow.app, not the bare binary.")
        }
    }

    func showPermissionsHelp() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showSetupHelp() {
        let problems = settings.setupProblems()
        let list = problems.isEmpty ? "Everything looks installed." : problems.map { "• \($0)" }.joined(separator: "\n")
        showAlert(
            title: "VoxFlow setup",
            text: """
            \(list)

            Missing models download automatically — or choose “Download models…” \
            from the VoxFlow menu.

            Missing engine: download the newest VoxFlow.app from the project’s \
            GitHub Releases page and replace this copy (or, if you built from \
            source, run ./setup.sh).
            """
        )
    }

    func openUpdatePage() {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }

    func copyLastTranscript() {
        guard let transcript = lastTranscriptValue else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    // MARK: - Helpers

    private func showAlert(title: String, text: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
