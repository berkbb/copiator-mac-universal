// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import Foundation
import Observation
import SwiftUI

/// Açık, koyu veya sistemi izleyen (otomatik) görünüm.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Klavye kısayolu verisi (UserDefaults için Codable ve Sendable).
struct KeyboardShortcutData: Codable, Equatable, Sendable {
    var key: String
    var isSpecialKey: Bool
    var specialKeyCode: UInt16?
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(
        key: String,
        isSpecialKey: Bool = false,
        specialKeyCode: UInt16? = nil,
        command: Bool = true,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = key
        self.isSpecialKey = isSpecialKey
        self.specialKeyCode = specialKeyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var keyEquivalent: KeyEquivalent {
        if isSpecialKey, let code = specialKeyCode {
            switch code {
            case 126: return .upArrow
            case 125: return .downArrow
            case 123: return .leftArrow
            case 124: return .rightArrow
            case 36: return .return
            case 48: return .tab
            case 49: return .space
            case 51: return .delete
            default:
                if let char = key.lowercased().first {
                    return KeyEquivalent(char)
                }
                return .return
            }
        }
        guard let char = key.lowercased().first else { return KeyEquivalent("?") }
        return KeyEquivalent(char)
    }

    var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        return mods
    }

    /// Klavye olayı bu kısayol mu? Özel tuşlar tuş koduyla, ötekiler niteleyicisiz karakterle karşılaştırılır;
    /// niteleyiciler (⌘ ⇧ ⌥ ⌃) birebir eşleşmelidir.
    func matches(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) == command, flags.contains(.shift) == shift,
              flags.contains(.option) == option, flags.contains(.control) == control else { return false }
        if isSpecialKey, let specialKeyCode { return keyCode == specialKeyCode }
        return characters?.uppercased() == key.uppercased()
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }

    var displayString: String {
        var str = ""
        if control { str += "⌃" }
        if option { str += "⌥" }
        if shift { str += "⇧" }
        if command { str += "⌘" }
        str += key.uppercased()
        return str
    }
}

/// Kullanıcı tarafından özelleştirilebilen eylemler (Transmission'daki kısayollara yakın).
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newJob
    case resume
    case pause
    case resumeAll
    case pauseAll
    case verify
    case remove
    case inspector

    var id: String { rawValue }

    /// Niteleyicisiz bir tuş atanabilir mi? Tüm eylemler menü kısayoludur; yazı yazarken tetiklenmemeleri için ⌘, ⌥ ya
    /// da ⌃ ister.
    var allowsBareKey: Bool { false }

    var titleKey: LKey {
        switch self {
        case .newJob: .menuNewJob
        case .resume: .menuResumeJob
        case .pause: .menuPauseJob
        case .resumeAll: .menuResumeAll
        case .pauseAll: .menuPauseAll
        case .verify: .menuVerify
        case .remove: .menuRemoveJob
        case .inspector: .menuInspector
        }
    }

    var defaultShortcut: KeyboardShortcutData {
        switch self {
        case .newJob: KeyboardShortcutData(key: "N", command: true)
        case .resume: KeyboardShortcutData(key: "R", command: true)
        case .pause: KeyboardShortcutData(key: ".", command: true)
        case .resumeAll: KeyboardShortcutData(key: "R", command: true, option: true)
        case .pauseAll: KeyboardShortcutData(key: ".", command: true, option: true)
        case .verify: KeyboardShortcutData(key: "V", command: true, shift: true)
        case .remove: KeyboardShortcutData(key: "⌫", isSpecialKey: true, specialKeyCode: 51, command: true)
        case .inspector: KeyboardShortcutData(key: "I", command: true)
        }
    }
}

/// Kullanıcı tercihleri (UserDefaults) ve yerelleştirilmiş metinler için tek kaynak.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let language = "language"
        static let appearance = "appearance"
        static let notifyOnFinish = "notifyOnFinish"
        static let resumeInterruptedAtLaunch = "resumeInterruptedAtLaunch"
        static let defaultCopyMode = "defaultCopyMode"
        static let defaultPreservePermissions = "defaultPreservePermissions"
        static let defaultPreserveXattrs = "defaultPreserveXattrs"
        static let defaultExcludeSystemFolders = "defaultExcludeSystemFolders"
        static let customEnginePath = "customEnginePath"
        static let checkUpdatesAtLaunch = "checkUpdatesAtLaunch"
        static let updateConsentAsked = "updateConsentAsked"
        static let sandboxEngine = "sandboxEngine"
        static let queueHeld = "queueHeld"
        static let customShortcuts = "customShortcuts"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let defaultAdvanced = "defaultAdvancedOptions"
        static let defaultVerifyAfterCopy = "defaultVerifyAfterCopy"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockProgress = "showDockProgress"
        static let all = [
            language, appearance, notifyOnFinish, resumeInterruptedAtLaunch, defaultCopyMode, defaultPreservePermissions,
            defaultPreserveXattrs, defaultExcludeSystemFolders, customEnginePath, checkUpdatesAtLaunch, updateConsentAsked,
            sandboxEngine, queueHeld, customShortcuts, keepDisplayAwake, defaultAdvanced, defaultVerifyAfterCopy,
            showMenuBarIcon, showDockProgress,
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let strings: StringTable

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            applySystemLanguage()
        }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }
    /// İş bitince (ya da hata verince) macOS bildirimi.
    var notifyOnFinish: Bool { didSet { defaults.set(notifyOnFinish, forKey: Key.notifyOnFinish) } }
    /// Uygulama iş çalışırken kapandıysa iş açılışta kendiliğinden sürsün mü (varsayılan: hayır, duraklatılmış bekler).
    var resumeInterruptedAtLaunch: Bool { didSet { defaults.set(resumeInterruptedAtLaunch, forKey: Key.resumeInterruptedAtLaunch) } }
    var defaultCopyMode: CopyMode { didSet { defaults.set(defaultCopyMode.rawValue, forKey: Key.defaultCopyMode) } }
    var defaultPreservePermissions: Bool { didSet { defaults.set(defaultPreservePermissions, forKey: Key.defaultPreservePermissions) } }
    var defaultPreserveXattrs: Bool { didSet { defaults.set(defaultPreserveXattrs, forKey: Key.defaultPreserveXattrs) } }
    var defaultExcludeSystemFolders: Bool { didSet { defaults.set(defaultExcludeSystemFolders, forKey: Key.defaultExcludeSystemFolders) } }
    var customEnginePath: String? { didSet { defaults.set(customEnginePath, forKey: Key.customEnginePath) } }
    /// Açılışta GitHub'a bağlanmak kullanıcının iznine bağlıdır; varsayılan kapalıdır.
    var checkUpdatesAtLaunch: Bool { didSet { defaults.set(checkUpdatesAtLaunch, forKey: Key.checkUpdatesAtLaunch) } }
    /// İlk açılışta izin bir kez sorulur.
    var updateConsentAsked: Bool { didSet { defaults.set(updateConsentAsked, forKey: Key.updateConsentAsked) } }
    /// rsync'i kum havuzunda (sandbox-exec) çalıştır; varsayılan açık.
    var sandboxEngine: Bool { didSet { defaults.set(sandboxEngine, forKey: Key.sandboxEngine) } }
    /// Kuyruk bekletiliyor: bekleyen işler başlamaz (çalışan iş sürer).
    var queueHeld: Bool { didSet { defaults.set(queueHeld, forKey: Key.queueHeld) } }
    /// İş sürerken ekranı da açık tut (`caffeinate -d` karşılığı); varsayılan kapalı, yalnızca sistem uykusu engellenir.
    var keepDisplayAwake: Bool { didSet { defaults.set(keepDisplayAwake, forKey: Key.keepDisplayAwake) } }
    /// Yeni işlerin gelişmiş rsync seçenekleri (Ayarlar › rsync); her iş Yeni İş sayfasında değiştirebilir.
    var defaultAdvanced: AdvancedOptions {
        didSet {
            if let data = try? JSONEncoder().encode(defaultAdvanced) { defaults.set(data, forKey: Key.defaultAdvanced) }
        }
    }
    /// Yeni işlerde kopyalama sonrası doğrulama.
    var defaultVerifyAfterCopy: VerifyAfterCopy {
        didSet { defaults.set(defaultVerifyAfterCopy.rawValue, forKey: Key.defaultVerifyAfterCopy) }
    }
    /// Menü çubuğu simgesi (ilerleme, tümünü duraklat/sürdür). Açıkken son pencere kapanınca uygulama çalışmayı sürdürür.
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    /// Dock simgesinde çalışan işin ilerlemesi ve bekleyen işlerin sayısı.
    var showDockProgress: Bool { didSet { defaults.set(showDockProgress, forKey: Key.showDockProgress) } }
    /// Kullanıcının özelleştirdiği kısayollar; varsayılandan farklı olanlar saklanır.
    var customShortcuts: [String: KeyboardShortcutData] {
        didSet {
            if let data = try? JSONEncoder().encode(customShortcuts) {
                defaults.set(data, forKey: Key.customShortcuts)
            }
        }
    }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        strings = StringTable(bundle: bundle)
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .tr
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        notifyOnFinish = defaults.object(forKey: Key.notifyOnFinish) as? Bool ?? true
        resumeInterruptedAtLaunch = defaults.object(forKey: Key.resumeInterruptedAtLaunch) as? Bool ?? false
        defaultCopyMode = CopyMode(rawValue: defaults.string(forKey: Key.defaultCopyMode) ?? "") ?? .folder
        defaultPreservePermissions = defaults.object(forKey: Key.defaultPreservePermissions) as? Bool ?? false
        defaultPreserveXattrs = defaults.object(forKey: Key.defaultPreserveXattrs) as? Bool ?? true
        defaultExcludeSystemFolders = defaults.object(forKey: Key.defaultExcludeSystemFolders) as? Bool ?? true
        customEnginePath = defaults.string(forKey: Key.customEnginePath)
        checkUpdatesAtLaunch = defaults.object(forKey: Key.checkUpdatesAtLaunch) as? Bool ?? false
        updateConsentAsked = defaults.object(forKey: Key.updateConsentAsked) as? Bool ?? false
        sandboxEngine = defaults.object(forKey: Key.sandboxEngine) as? Bool ?? true
        queueHeld = defaults.object(forKey: Key.queueHeld) as? Bool ?? false
        keepDisplayAwake = defaults.object(forKey: Key.keepDisplayAwake) as? Bool ?? false
        defaultAdvanced = defaults.data(forKey: Key.defaultAdvanced)
            .flatMap { try? JSONDecoder().decode(AdvancedOptions.self, from: $0) } ?? AdvancedOptions()
        defaultVerifyAfterCopy = VerifyAfterCopy(rawValue: defaults.string(forKey: Key.defaultVerifyAfterCopy) ?? "") ?? .off
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        showDockProgress = defaults.object(forKey: Key.showDockProgress) as? Bool ?? true
        if let data = defaults.data(forKey: Key.customShortcuts),
           let decoded = try? JSONDecoder().decode([String: KeyboardShortcutData].self, from: data) {
            customShortcuts = decoded
        } else {
            customShortcuts = [:]
        }
    }

    /// Yeni işin varsayılan seçenekleri. `--delete` hiçbir zaman varsayılan değildir: her işte ayrıca seçilip onaylanır.
    var defaultOptions: CopyOptions {
        CopyOptions(
            copyMode: defaultCopyMode, preservePermissions: defaultPreservePermissions,
            preserveExtendedAttributes: defaultPreserveXattrs, deleteExtraneous: false,
            excludeSystemFolders: defaultExcludeSystemFolders, advanced: defaultAdvanced, verifyAfterCopy: defaultVerifyAfterCopy
        )
    }

    func resetAll() {
        language = .tr
        appearance = .system
        notifyOnFinish = true
        resumeInterruptedAtLaunch = false
        defaultCopyMode = .folder
        defaultPreservePermissions = false
        defaultPreserveXattrs = true
        defaultExcludeSystemFolders = true
        customEnginePath = nil
        checkUpdatesAtLaunch = false
        updateConsentAsked = false
        sandboxEngine = true
        queueHeld = false
        keepDisplayAwake = false
        defaultAdvanced = AdvancedOptions()
        defaultVerifyAfterCopy = .off
        showMenuBarIcon = true
        showDockProgress = true
        customShortcuts = [:]
        // Özellik gözlemcileri değerleri yeniden yazdı; ilk kurulumdaki gibi hiçbir tercih kalmasın.
        // "AppleLanguages" en sonda silinir: dil atanırken yeniden yazılıyordu.
        Key.all.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "AppleLanguages")
    }

    // MARK: - Kısayol yönetimi

    func shortcut(for action: ShortcutAction) -> KeyboardShortcutData {
        customShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcutData, for action: ShortcutAction) {
        if shortcut == action.defaultShortcut {
            customShortcuts.removeValue(forKey: action.rawValue)
        } else {
            customShortcuts[action.rawValue] = shortcut
        }
    }

    func resetShortcut(for action: ShortcutAction) {
        customShortcuts.removeValue(forKey: action.rawValue)
    }

    func resetAllShortcuts() {
        customShortcuts = [:]
    }

    var isAllShortcutsDefault: Bool {
        ShortcutAction.allCases.allSatisfy { isDefaultShortcut(for: $0) }
    }

    func isDefaultShortcut(for action: ShortcutAction) -> Bool {
        customShortcuts[action.rawValue] == nil || customShortcuts[action.rawValue] == action.defaultShortcut
    }

    /// Tüm pencerelere (Ayarlar ve Hakkında dahil) seçilen görünümü uygular.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// AppKit'in sistem menüleri bir sonraki açılışta seçilen dili kullansın.
    private func applySystemLanguage() {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    // MARK: - Yerelleştirme ve biçimlendirme

    var languageCode: String { language.resolvedCode() }
    var locale: Locale { Locale(identifier: languageCode) }

    func t(_ key: LKey) -> String {
        strings.string(key, language: languageCode)
    }

    func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    /// Biçim değişkenleri metin olarak saklanan (ör. günlük satırları) bir anahtarı biçimler.
    func t(_ key: LKey, arguments: [String]) -> String {
        guard !arguments.isEmpty else { return t(key) }
        return String(format: t(key), locale: locale, arguments: arguments.map { $0 as CVarArg })
    }

    /// Gelişmiş seçeneklerdeki bir sorunun açıklaması.
    func problem(_ problem: AdvancedOptions.Problem) -> String {
        func field(_ name: String) -> String {
            let key: LKey = switch name {
            case "includeFromFile": .advIncludeFrom
            case "excludeFromFile": .advExcludeFrom
            case "filesFromFile": .advFilesFrom
            case "referenceDirectory": .advReferenceDirectory
            case "backupDirectory": .advBackupDirectory
            case "logFile": .advLogFile
            default: .advBatchFile
            }
            return t(key)
        }
        return switch problem {
        case .invalidPattern(let pattern): t(.problemPattern, OpenSafety.visibleName(pattern))
        case .invalidChmod: t(.problemChmod)
        case .invalidIconv: t(.problemIconv)
        case .invalidSuffix: t(.problemSuffix)
        case .invalidNumber: t(.problemNumber)
        case .pathNotAbsolute(let name): t(.problemPath, field(name))
        case .writesInsideSource(let name): t(.problemWritesInsideSource, field(name))
        case .missingReferenceDirectory: t(.problemReference)
        case .missingBatchFile: t(.problemBatch)
        case .stopAtInPast: t(.problemStopAt)
        case .invalidRetention: t(.problemRetention)
        }
    }

    func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }

    /// Kalan süre: "3 dk 12 sn", "1 sa 4 dk".
    func duration(seconds: Int) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated).locale(locale))
    }

    func result(_ result: JobResult) -> String {
        strings.resultMessage(result, language: languageCode, bytes: bytes)
    }

    func log(_ entry: JobLogEntry) -> String {
        strings.logText(entry, language: languageCode)
    }
}
