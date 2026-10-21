// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Arayüz dilleri. `system`, macOS'un tercih ettiği dili izler.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case tr
    case ro

    public static let supportedCodes = ["en", "tr", "ro"]

    public var id: String { rawValue }

    public var nativeName: String? {
        switch self {
        case .system: nil
        case .en: "English"
        case .tr: "Türkçe"
        case .ro: "Română"
        }
    }

    public var flag: String {
        switch self {
        case .system: "🌐"
        case .en: "🇬🇧"
        case .tr: "🇹🇷"
        case .ro: "🇷🇴"
        }
    }

    public func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? String(identifier.prefix(2))
            if Self.supportedCodes.contains(code) { return code }
        }
        return "en"
    }
}

/// Her dil için Localizable.strings tablolarını tutar; uygulama içinde anında dil değişimine izin verir.
public struct StringTable: Sendable {
    public let tables: [String: [String: String]]

    public init(tables: [String: [String: String]]) {
        self.tables = tables
    }

    public init(bundle: Bundle) {
        var loaded: [String: [String: String]] = [:]
        for code in AppLanguage.supportedCodes {
            if let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
               let table = Self.load(contentsOf: url) {
                loaded[code] = table
            }
        }
        self.init(tables: loaded)
    }

    public static func load(contentsOf url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    /// Eksik çeviride İngilizceye, o da yoksa anahtarın kendisine düşer.
    public func string(_ key: LKey, language code: String) -> String {
        tables[code]?[key.rawValue] ?? tables["en"]?[key.rawValue] ?? key.rawValue
    }
}

/// Tüm arayüz metinlerinin anahtarları. Her anahtar tr/en/ro tablolarında birebir bulunmalıdır (testlerle denetlenir).
public enum LKey: String, CaseIterable, Sendable {
    // Genel
    case appName, appTagline, yes, no, unknown
    case buttonCancel, buttonOK, buttonChoose, buttonClose, buttonCopy, buttonShowInFinder, buttonRemove
    // Menüler
    case menuAbout, menuCheckEngineUpdates, menuCheckAppUpdates, menuNewJob, menuJob
    case menuResumeJob, menuPauseJob, menuResumeAll, menuPauseAll, menuRunAgain
    case menuVerify, menuVerifyChecksum, menuShowSource, menuShowDestination, menuRemoveJob, menuRemoveFinished
    case menuInspector, menuEngineManual, menuWebsite
    // Araç çubuğu
    case toolbarNewJob, toolbarResume, toolbarPause, toolbarVerify, toolbarRemove, toolbarInspector
    case toolbarHoldQueue, toolbarReleaseQueue, queueHeldNotice
    // Kenar çubuğu
    case sidebarQueue, filterAll, filterActive, filterPaused, filterFinished, filterFailed, emptyFilter
    // Karşılama
    case welcomeTitle, welcomeSubtitle, welcomeDropHint, welcomeFootnote
    // Motor durumu
    case engineReady, engineLimited, engineChecking, engineMissingTitle, engineMissingMessage, engineBlockedTitle, engineBlockedMessage
    // İş durumu
    case statusWaiting, statusScanning, statusCopying, statusPaused, statusFinished, statusFailed, statusInterrupted
    // İlerleme
    case progressBytes, progressSpeed, progressRemaining, progressFiles, progressChecked, progressEstimating, progressLimited
    case progressPreparing, progressCancelling, progressVerifying, progressUpdatingEngine
    // Sonuçlar
    case resultSucceeded, resultSucceededWithNotes, resultSourceFilesVanished, resultPartial, resultCancelled
    case resultDestinationFull, resultDestinationFullDetail, resultDestinationFilling, resultDestinationReadOnly
    case resultPermissionDenied, resultSourceMissing, resultDestinationMissing, resultOverlapping, resultEngineMissing
    case resultUnsupported, resultIOError, resultFailed
    // Yeni iş
    case newJobTitle, newJobSource, newJobDestination, newJobDropSource, newJobMode, newJobOptions, newJobAdd
    case modeFolder, modeContents, modeFolderHelp, modeContentsHelp, modeFileHelp
    case optionPreservePermissions, optionPreservePermissionsNote, optionPermissionsUnavailable
    case optionXattrs, optionXattrsNote, optionExcludeSystem, optionExcludeSystemNote, optionDelete, optionDeleteWarning
    case deleteConfirmTitle, deleteConfirmMessage, deleteConfirmButton
    case panelChooseSource, panelChooseDestination
    // Ayrıntılar
    case detailNoSelection, detailSource, detailDestination, detailTarget, detailMode, detailOptions, detailStatus
    case detailResult, detailStarted, detailFinished, detailLog, detailNoLog, detailExitCode, detailCreated
    // Günlük
    case logStarted, logResumed, logFinished, logPaused, logFailed, logInterrupted, logProtectedSkipped, logLimitedFileSystem
    case logLimitedProgress, logHarmlessNotes, logQuarantineApplied, logVerified
    // Doğrulama
    case verifyTitle, verifyChooseTitle, verifyChooseMessage, verifyQuick, verifyChecksum
    case verifyIdentical, verifyIdenticalChecksum, verifySummary, verifyShowAttributes, verifyFailed, verifyNothingToShow
    case kindMissing, kindChanged, kindAttributes, kindExtra
    // Bildirimler ve tostlar
    case notifyFinishedTitle, notifyFinishedBody, notifyFailedTitle, notifyFailedBody
    case toastJobAdded, toastEngineUpdated
    // Hatalar
    case errorTitle, warningTitle, errorEngineNotFound, errorEngineTimeout, errorCancelled, errorFailed
    case errorStoreCorrupt, errorSaveFailed, errorEngineBuildTools
    // Ayarlar
    case settingsGeneral, settingsCopying, settingsShortcuts, settingsAdvanced
    case settingsLanguage, languageSystem, restartWarningTitle, restartMenuBarNotice
    case settingsAppearance, appearanceSystem, appearanceLight, appearanceDark
    case settingsNotify, settingsResumeInterrupted, settingsResumeInterruptedNote
    case settingsDefaultsSection, settingsDefaultsNote
    case settingsEngine, settingsEnginePath, settingsEngineVersion, settingsEngineCheck, settingsEngineNotFound
    case settingsEngineUseCustom, settingsEngineLimitedNote, settingsSandbox, settingsSandboxNote
    case settingsReset, settingsResetConfirm
    case updateSection, updateCheck, updateInstall, updateChecking, updateInstalling, updateAvailable
    case updateUpToDate, updateInstalled, updateFailed, updateAutoCheck, updateSource, updateBuildNote
    case appUpdateSection, appUpdateAvailable, appUpdateUpToDate, appUpdateDownload, appUpdateNoReleases, appVersionLabel
    case consentTitle, consentMessage, consentAllow, consentDeny
    // Kısayollar
    case shortcutCustomSection, shortcutRecordPrompt, shortcutResetDefault, shortcutResetAll, shortcutRecordHelp
    case shortcutModifierRequired, shortcutConflictWarning
    // Hakkında ve lisanslar
    case aboutVersion, aboutPoweredBy, aboutEngineCredit, aboutAppLicense, aboutEngineLicense, aboutNotices, aboutCopyright
    case aboutRepository, aboutEngineWebsite
    case licenseAppSubtitle, licenseEngineSubtitle, licenseNoticesSubtitle, licenseReadOnly, licensePublisher, licenseLabel
    case licenseCopyText, licenseCopied
    // Süre sınırı, düşürülen seçenekler, istatistikler
    case resultStoppedAtLimit, logDroppedOptions, logStatsHeader, notifyStoppedTitle, notifyStoppedBody
    // Uyku ve güç
    case sleepPreventedVerified, sleepPreventedUnverified, sleepDisplayKept, sleepRestored, sleepRestoreUnverified
    case toastSleepPrevented, toastSleepRestored, sleepBadge, sleepBadgeHelp
    case adviceOnBattery, adviceBatteryLow, adviceBatteryCritical, adviceLowPowerMode, adviceDisplaySleep, adviceLid, adviceOnAC
    case settingsPowerSection, settingsKeepDisplayAwake, settingsKeepDisplayAwakeNote
    // Gelişmiş rsync seçenekleri
    case settingsRsync, settingsRsyncNote, newJobAdvanced, newJobCommand, buttonClear, advNotSet
    case advSelection, advAttributes, advLinks, advWriting, advDeletion, advComparison, advSnapshots, advProgress
    case advFilterRules, advIncludePatterns, advExcludePatterns, advPatternsNote, advUseFilterFiles
    case advIncludeFrom, advExcludeFrom, advFilesFrom, advFilesFromNote, advMaxSize, advMinSize
    case advIgnoreExisting, advExistingOnly, advUpdateOnly, advPruneEmpty
    case advHardLinks, advHardLinksNote, advCreationTimes, advAccessTimes, advNumericIDs, advOneFileSystem, advChmod, advChmodNote
    case advSymlinks, symlinkPreserve, symlinkCopyTargets, symlinkCopyUnsafe, symlinkSkipUnsafe
    case advSparse, advInplace, advInplaceNote, advWholeFile, advWholeFileNote, advAppend, appendOff, appendOn, appendVerify
    case advDeleteTiming, deleteDuring, deleteBefore, deleteAfter, deleteDelay, advDeleteExcluded, advMaxDelete, advIgnoreErrors, advDeleteNote
    case advSizeOnly, advModifyWindow, advBandwidth, advStopAfter, advStopAt, advStopNote, advIconv, advIconvNote
    case advReferenceMode, referenceNone, referenceLink, referenceCompare, referenceCopy, advReferenceDirectory, advReferenceNote
    case advKeepBackups, advBackupDirectory, advBackupSuffix, advBackupsNote
    case advProgressDetail, progressDetailTotal, progressDetailPerFile, advShowFileNames, advFileListProgress, advFileListNote
    case advShowStats, advLogChanges, advLogChangesNote, advPreciseProgress, advPreciseNote, advLogFile
    case advBatchMode, batchOff, batchWrite, batchOnlyWrite, advBatchFile, advUnavailableNote
    case problemPattern, problemChmod, problemIconv, problemSuffix, problemNumber, problemPath, problemWritesInsideSource
    case problemReference, problemBatch, problemStopAt
    case progressCurrentItem, progressListing, progressThisFile
    // Kum havuzu nedeniyle yapılamayanlar
    case sandboxLimitsTitle, sandboxLimitsFooter
    case sandboxLimitNetworkTitle, sandboxLimitNetwork, sandboxLimitSourceTitle, sandboxLimitSource
    case sandboxLimitProgramsTitle, sandboxLimitPrograms, sandboxLimitPersonalTitle, sandboxLimitPersonal
    case sandboxLimitNotOfferedTitle, sandboxLimitNotOffered
}

extension StringTable {
    /// Bir sonuç sınıfının kullanıcıya gösterilen açıklaması (biçim değişkenleri doldurulmuş).
    /// - Parameter bytes: Bayt sayısını seçili dilde biçimleyen işlev.
    public func resultMessage(_ result: JobResult, language code: String, bytes: (Int64) -> String) -> String {
        let locale = Locale(identifier: code)
        func format(_ key: LKey, _ arguments: any CVarArg...) -> String {
            String(format: string(key, language: code), locale: locale, arguments: arguments)
        }
        switch result.kind {
        case .succeeded: return string(.resultSucceeded, language: code)
        case .succeededWithNotes: return format(.resultSucceededWithNotes, result.noteCount)
        case .sourceFilesVanished: return string(.resultSourceFilesVanished, language: code)
        case .partial: return format(.resultPartial, result.noteCount)
        case .cancelled: return string(.resultCancelled, language: code)
        case .stoppedAtLimit: return string(.resultStoppedAtLimit, language: code)
        case .destinationFull:
            if let required = result.requiredBytes, let available = result.availableBytes {
                return format(.resultDestinationFullDetail, bytes(required), bytes(available))
            }
            if let available = result.availableBytes { return format(.resultDestinationFilling, bytes(available)) }
            return string(.resultDestinationFull, language: code)
        case .destinationReadOnly: return string(.resultDestinationReadOnly, language: code)
        case .permissionDenied: return string(.resultPermissionDenied, language: code)
        case .sourceMissing: return string(.resultSourceMissing, language: code)
        case .destinationMissing: return string(.resultDestinationMissing, language: code)
        case .overlapping: return string(.resultOverlapping, language: code)
        case .engineMissing: return string(.resultEngineMissing, language: code)
        case .unsupported: return string(.resultUnsupported, language: code)
        case .ioError: return string(.resultIOError, language: code)
        case .failed: return format(.resultFailed, Int(result.exitCode ?? -1))
        }
    }

    /// Günlük satırının gösterilecek metni: anahtar varsa çevrilir, yoksa ham çıktı.
    public func logText(_ entry: JobLogEntry, language code: String) -> String {
        if let raw = entry.key, let key = LKey(rawValue: raw) {
            let template = string(key, language: code)
            guard !entry.arguments.isEmpty else { return template }
            return String(format: template, locale: Locale(identifier: code), arguments: entry.arguments.map { $0 as CVarArg })
        }
        return entry.raw ?? ""
    }
}
