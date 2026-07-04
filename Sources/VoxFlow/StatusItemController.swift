import AppKit

enum DictationState {
    case idle
    case recording
    case processing
}

protocol StatusMenuDelegate: AnyObject {
    var cleanupEnabled: Bool { get }
    var assistEnabled: Bool { get }
    var readBackEnabled: Bool { get }
    var currentModel: ModelChoice { get }
    var currentHotkey: Hotkey { get }
    var launchAtLoginEnabled: Bool { get }
    var lastTranscript: String? { get }
    var setupProblems: [String] { get }
    var currentError: String? { get }
    var downloadStatus: String? { get }
    var modelsAreMissing: Bool { get }

    func toggleCleanup()
    func toggleAssist()
    func toggleReadBack()
    func speakLastTranscript()
    func startModelDownload()
    func selectModel(_ model: ModelChoice)
    func selectHotkey(_ hotkey: Hotkey)
    func toggleLaunchAtLogin()
    func showPermissionsHelp()
    func showSetupHelp()
    func copyLastTranscript()
}

/// Menu bar icon + menu. Icon reflects state (SPEC R3/R5); menu is rebuilt
/// each time it opens so toggles and errors are always current.
final class StatusItemController: NSObject, NSMenuDelegate {
    weak var delegate: StatusMenuDelegate?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        setState(.idle)
    }

    func setState(_ state: DictationState) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let description: String
        switch state {
        case .idle:
            symbolName = "mic"
            description = "VoxFlow idle"
        case .recording:
            symbolName = "mic.fill"
            description = "VoxFlow recording"
        case .processing:
            symbolName = "waveform"
            description = "VoxFlow processing"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        button.appearsDisabled = false
    }

    /// Brief visual blip used when a dictation produced no text.
    /// Applied on the next runloop tick so a same-tick setState(.idle)
    /// (e.g. from a deferred cleanup) can't wipe the flash instantly.
    func flashIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            button.appearsDisabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                button.appearsDisabled = false
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let delegate = delegate else { return }

        // Error banner (SPEC R15)
        if let error = delegate.currentError {
            let item = NSMenuItem(title: "⚠️ \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Download progress (in-app model download — no terminal needed)
        if let status = delegate.downloadStatus {
            let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else if delegate.modelsAreMissing {
            let item = NSMenuItem(title: "Download models…", action: #selector(downloadAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        } else if !delegate.setupProblems.isEmpty {
            // Anything left that a download can't fix (missing server binaries)
            let item = NSMenuItem(title: "Setup needed…", action: #selector(setupHelpAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Last transcript (click = copy)
        if let transcript = delegate.lastTranscript, !transcript.isEmpty {
            let preview = transcript.count > 60
                ? String(transcript.prefix(60)) + "…"
                : transcript
            let item = NSMenuItem(title: "“\(preview)”  (click to copy)",
                                  action: #selector(copyTranscriptAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let hint = NSMenuItem(title: "\(delegate.currentHotkey.label) and speak",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())

        // AI cleanup toggle
        let cleanup = NSMenuItem(title: "AI Cleanup", action: #selector(toggleCleanupAction), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = delegate.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)

        // Dyslexia & ADHD assist (applies when cleanup is on)
        let assist = NSMenuItem(title: "Dyslexia & ADHD Assist", action: #selector(toggleAssistAction), keyEquivalent: "")
        assist.target = self
        assist.state = delegate.assistEnabled ? .on : .off
        assist.toolTip = "Reorders scattered ideas, merges repeats, fixes homophones. Needs AI Cleanup on."
        menu.addItem(assist)

        // Read back the inserted text aloud
        let readBack = NSMenuItem(title: "Read Back After Insert", action: #selector(toggleReadBackAction), keyEquivalent: "")
        readBack.target = self
        readBack.state = delegate.readBackEnabled ? .on : .off
        menu.addItem(readBack)

        if delegate.lastTranscript != nil {
            let speak = NSMenuItem(title: "Speak Last Dictation", action: #selector(speakAction), keyEquivalent: "")
            speak.target = self
            menu.addItem(speak)
        }

        // Model submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for choice in ModelChoice.allCases {
            let item = NSMenuItem(title: choice.label, action: #selector(selectModelAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == delegate.currentModel ? .on : .off
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Hotkey submenu
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for choice in Hotkey.allCases {
            let item = NSMenuItem(title: choice.label, action: #selector(selectHotkeyAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == delegate.currentHotkey ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // Launch at login
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        login.state = delegate.launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let perms = NSMenuItem(title: "Permissions help…", action: #selector(permissionsAction), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        let quit = NSMenuItem(title: "Quit VoxFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleCleanupAction() { delegate?.toggleCleanup() }
    @objc private func toggleAssistAction() { delegate?.toggleAssist() }
    @objc private func toggleReadBackAction() { delegate?.toggleReadBack() }
    @objc private func speakAction() { delegate?.speakLastTranscript() }
    @objc private func downloadAction() { delegate?.startModelDownload() }

    @objc private func selectModelAction(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let choice = ModelChoice(rawValue: raw)
        else { return }
        delegate?.selectModel(choice)
    }

    @objc private func selectHotkeyAction(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let choice = Hotkey(rawValue: raw)
        else { return }
        delegate?.selectHotkey(choice)
    }

    @objc private func toggleLoginAction() { delegate?.toggleLaunchAtLogin() }
    @objc private func permissionsAction() { delegate?.showPermissionsHelp() }
    @objc private func setupHelpAction() { delegate?.showSetupHelp() }
    @objc private func copyTranscriptAction() { delegate?.copyLastTranscript() }
}
