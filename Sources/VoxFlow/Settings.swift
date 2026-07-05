import Foundation
import CoreGraphics

// MARK: - Shared contract types (pinned in SPEC.md)

enum AppCategory: String {
    case aiChat
    case email
    case messaging
    case general
}

enum Hotkey: String, CaseIterable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .fn: return 63
        case .rightCommand: return 54
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        }
    }

    /// Device-specific flag bit distinguishing the RIGHT-side key from the left
    /// (.maskAlternate/.maskCommand are set for either side). Fn has no sides.
    /// NX_DEVICERALTKEYMASK = 0x40, NX_DEVICERCMDKEYMASK = 0x10.
    var deviceFlagBit: UInt64? {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .fn: return nil
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Hold Right Option (⌥)"
        case .fn: return "Hold Fn (🌐)"
        case .rightCommand: return "Hold Right Command (⌘)"
        }
    }
}

enum ModelChoice: String, CaseIterable {
    case englishFast
    case multilingual
    case highAccuracy

    var fileName: String {
        switch self {
        case .englishFast: return "ggml-base.en.bin"
        case .multilingual: return "ggml-small.bin"
        case .highAccuracy: return "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    /// Language parameter passed to whisper-server.
    var language: String {
        switch self {
        case .englishFast: return "en"
        case .multilingual: return "auto"
        case .highAccuracy: return "auto"
        }
    }

    var label: String {
        switch self {
        case .englishFast: return "English (fast)"
        case .multilingual: return "Multilingual (auto-detect)"
        case .highAccuracy: return "High Accuracy (slower, all languages)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// Minimum plausible size in MB, used to detect truncated downloads.
    var minSizeMB: Int {
        switch self {
        case .englishFast: return 100
        case .multilingual: return 400
        case .highAccuracy: return 500
        }
    }
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkey = "hotkey"
        static let model = "modelChoice"
        static let cleanup = "cleanupEnabled"
        static let assist = "assistModeEnabled"
        static let readBack = "readBackEnabled"
    }

    var hotkey: Hotkey {
        get { Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    /// Default depends on the Mac: Apple Silicon flies through the big model;
    /// Intel gets the fast English model so dictation feels instant.
    static var defaultModelChoice: ModelChoice {
        #if arch(arm64)
        return .highAccuracy
        #else
        return .englishFast
        #endif
    }

    var modelChoice: ModelChoice {
        get { ModelChoice(rawValue: defaults.string(forKey: Key.model) ?? "") ?? Settings.defaultModelChoice }
        set { defaults.set(newValue.rawValue, forKey: Key.model) }
    }

    /// AI cleanup is OFF by default on first run (SPEC).
    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanup) }
        set { defaults.set(newValue, forKey: Key.cleanup) }
    }

    /// Dyslexia & ADHD assist: reorganizes jumbled ideas and aggressively fixes
    /// homophones/spelling during cleanup. Applies when cleanup is enabled.
    var assistModeEnabled: Bool {
        get { defaults.bool(forKey: Key.assist) }
        set { defaults.set(newValue, forKey: Key.assist) }
    }

    /// Speak the final text aloud after inserting it (proofread by ear).
    var readBackEnabled: Bool {
        get { defaults.bool(forKey: Key.readBack) }
        set { defaults.set(newValue, forKey: Key.readBack) }
    }

    static let llmDownloadURL = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
    static let llmMinSizeMB = 500

    // MARK: Paths

    var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/models", isDirectory: true)
    }

    var whisperModelPath: URL {
        modelsDirectory.appendingPathComponent(modelChoice.fileName)
    }

    var llmModelPath: URL {
        modelsDirectory.appendingPathComponent("qwen2.5-1.5b-instruct-q4_k_m.gguf")
    }

    // MARK: Setup verification

    /// Missing pieces required for DICTATION. Empty means ready to dictate.
    /// Cleanup problems are deliberately separate: they must never block dictation.
    func whisperProblems() -> [String] {
        var problems: [String] = []
        if ServerManager.brewBinary("whisper-server") == nil {
            problems.append("Speech engine missing — please re-download VoxFlow.app (or: brew install whisper-cpp)")
        }
        if !FileManager.default.fileExists(atPath: whisperModelPath.path) {
            problems.append("Missing model — choose “Download models…” from the VoxFlow menu")
        }
        return problems
    }

    /// Missing pieces for optional AI cleanup only.
    func cleanupProblems() -> [String] {
        var problems: [String] = []
        if ServerManager.brewBinary("llama-server") == nil {
            problems.append("Cleanup engine missing — please re-download VoxFlow.app (or: brew install llama.cpp)")
        }
        if !FileManager.default.fileExists(atPath: llmModelPath.path) {
            problems.append("Missing cleanup model — choose “Download models…” from the VoxFlow menu")
        }
        return problems
    }

    /// Combined list for the "Setup needed…" menu banner.
    func setupProblems() -> [String] {
        var problems = whisperProblems()
        if cleanupEnabled {
            problems.append(contentsOf: cleanupProblems())
        }
        return problems
    }

    // MARK: App category map (pinned in SPEC.md)

    static let categoryMap: [String: AppCategory] = [
        // AI chat apps → structure the prompt
        "com.anthropic.claudefordesktop": .aiChat,
        "com.openai.chat": .aiChat,
        "com.todesktop.230313mzl4w4u92": .aiChat, // Cursor
        "ai.perplexity.mac": .aiChat,
        "com.exafunction.windsurf": .aiChat,
        // Email → light cleanup
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.SparkDesktop": .email,
        "com.readdle.smartemail-Mac": .email,
        // Messaging → minimal touch-up
        "com.apple.MobileSMS": .messaging,
        "com.tinyspeck.slackmacgap": .messaging,
        "net.whatsapp.WhatsApp": .messaging,
        "com.hnc.Discord": .messaging,
        "ru.keepcoder.Telegram": .messaging,
        "org.telegram.desktop": .messaging,
        "com.facebook.archon": .messaging, // Messenger
    ]
}
