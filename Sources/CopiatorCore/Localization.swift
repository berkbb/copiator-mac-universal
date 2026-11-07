// SPDX-License-Identifier: GPL-3.0-only
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
    case resultSandboxUnavailable, settingsSandboxUnavailable
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
    // Anlık görüntüler
    case logSnapshotStarted, logSnapshotFirst, logSnapshotResumed, logSnapshotCreated, logSnapshotPartialKept
    case logSnapshotFinalizeFailed, logSnapshotPruned, logSnapshotPruneFailed
    case sectionSnapshots, optionSnapshots, optionSnapshotsNote, snapshotKeepLast, snapshotKeepDaily, snapshotKeepWeekly
    case snapshotKeepMonthly, snapshotRetentionNote, snapshotReferenceIgnored, problemRetention
    case retentionConfirmTitle, retentionConfirmMessage, retentionConfirmButton
    case detailSnapshots, detailSnapshotsCount, detailSnapshotsNone
    // Kopyalama sonrası doğrulama
    case statusVerifying, resultVerificationFailed, resultVerificationIncomplete
    case logVerifyAfterCopyQuick, logVerifyAfterCopyChecksum, logVerifyAfterCopyPassed, logVerifyAfterCopyDifferences
    case logVerifyAfterCopyIncomplete
    case optionVerifyAfterCopy, optionVerifyAfterCopyNote, verifyAfterOff, verifyAfterQuick, verifyAfterChecksum
    // Disk takılınca başlatma
    case sectionAutomation, optionRunWhenConnected, optionRunWhenConnectedNote, statusWaitingForDisk
    case logSuspendedForDisk, logResumedAfterDisk, logStartedOnConnect, toastSuspendedForDisk
    // Hazır dışlama listeleri
    case advExcludePresets, advExcludePresetsNote, presetDeveloper, presetVersionControl, presetCaches, presetMacOSJunk
    // Düzenleme, çoğaltma, önizleme
    case menuEditJob, menuDuplicateJob, editJobTitle, editJobSave, logEdited, toastJobUpdated
    case newJobPreview, previewTitle, previewSummary, previewSummaryKept, previewNothing, previewDeleteWarning
    case previewWillCopy, previewWillUpdate, previewWillDelete, previewKept, previewAttributes
    // Geçmiş ve yetim süreçler
    case detailHistory, detailNoHistory, historySnapshot, historyDifferences, logOrphanStopped
    // Menü çubuğu ve Dock
    case settingsInterfaceSection, settingsMenuBarIcon, settingsMenuBarIconNote, settingsDockProgress
    case menuBarIdle, menuBarProgress, menuBarWaiting, menuBarOpen, menuBarQuit
    // Kestirmeler
    case intentRunJobTitle, intentRunJobDescription, intentJobParameter, intentJobTypeName, intentRunJobStarted
    case intentJobNotFound, intentJobCannotRun, intentPauseAllTitle, intentPauseAllDescription, intentPauseAllDone
    case intentResumeAllTitle, intentResumeAllDescription, intentResumeAllDone, shortcutRunJob, shortcutPauseAll, shortcutResumeAll
    case settingsShortcutsAppSection, settingsShortcutsAppNote
    // Kuyruğu temizleme
    case toolbarClear, menuRemoveAll, removeAllConfirmTitle, removeAllConfirmMessage, removeAllConfirmButton
    // Rutinler
    case logRulesMatched, logRulesNewlineSkipped, logRuleRegexTooComplex, routineSampleTooComplex, logPlacementLinksSkipped
    // Hedefte yerleşim (alt klasör ve ad şablonları)
    case placementTitle, placementFolder, placementFolderPrompt, placementPresets, placementPresetYearMonthName, placementPresetYearMonth
    case placementPresetYear, placementKeepStructure, placementName, placementNamePrompt, placementInsertToken, placementTokenName
    case placementTokenFolder, placementTokenYear, placementTokenYY, placementTokenMonth, placementTokenMonthName, placementTokenDay
    case placementDateSource, placementDateAutomatic, placementDateFileName, placementDateContents, placementDateCapture
    case placementDateModified, placementDateCreated, placementExample, placementNote, placementSampleFile, placementSameName
    case problemPlacementToken, problemPlacementSlash, problemPlacementParent
    // Adlandırma kipleri: hedef belirteçleri ve ad düzeltmeleri
    case placementTokenTargetFolder, placementTokenTargetNumber, problemPlacementFix, problemPlacementFixReplacement
    case placementFixes, placementFixPattern, placementFixReplacement, placementFixAdd, placementFixPresets, placementFixPresetCode
    case placementFixPresetSpaces, placementFixPresetUnderscores, placementFixRemove, placementFixNote, placementFixesSummary
    // Önerili yerleştirme ("Klasörü sor")
    case logAwaitingPlacement, logPlacementsDecided, notifyPlacementBody, placementAskFolder, placementAskFolderNote, placementLearned
    case placementForget, placementSheetTitle, placementSheetNote, placementSkip, placementNewFolder
    case placementNewFolderPrompt, placementRoot, placementRemember, placementRememberNote, placementWillBe, placementNoSuggestion
    case placementApply, placementMore, placementAskSummary, placementRankAll, resultAwaitingPlacement
    // Hedefte kopyası var ölçütü
    case ruleAttrInDestination, ruleOpExists, ruleOpNotExists
    // Seçili öğeleri rutine gönderme, hedef özeti, klasör önerisi
    case sendToRoutineTitle, sendToRoutineNone, sendToRoutineNoneNote, sendToRoutineNote, sendToRoutineNoItems, logRoutineOnItems
    case detailSelectedItems, intentRunRoutineOnFilesTitle, intentRunRoutineOnFilesDescription, intentFilesParameter
    case menuDestinationSummary, summaryScanning, summaryFailed, summaryVolume, summaryCounts, summaryFolders, summaryExtensions
    case summaryRootFiles, summaryNoExtension, suggestFolders, suggestFoldersQuery, suggestFoldersPrompt, suggestFoldersEmpty
    case suggestFoldersNone, suggestFoldersNote
    // Taşıma (doğrulayıp Çöp'e) ve temizleme aracı
    case logSourcesTrashed, logSourceTrashFailed, optionTrashSource, optionTrashSourceNote, trashConfirmTitle, trashConfirmMessage
    case trashConfirmButton, menuCleanupArchived, cleanupTitle, cleanupNote, cleanupScan, cleanupScanning, cleanupNone, cleanupFound
    case cleanupMove, cleanupConfirmTitle, cleanupConfirmMessage, cleanupDone, cleanupOverlap, cleanupMore
    // Cihaz üstü yapay zekâ önerileri
    case settingsAISuggestions, settingsAISuggestionsNote, aiRankFolders, aiRanked, aiNoAnswer, aiSuggestTemplate
    case aiTemplateSuggestion, aiUseSuggestion, aiThinking, aiNoTemplate, aiLanguageWarning
    // Yerel model sunucuları (Ollama, LM Studio) ve yol önerileri
    case settingsAISection, settingsAIProvider, settingsAIModel, settingsAIRefresh, settingsAIServerOff, settingsAINoLocalModel
    case settingsAIModelMissing, settingsAIReady, settingsAILocalNote, aiSuggestFolderTemplate
    case aiNoFolderTemplate, placementAINewFolder, placementAISuggested, settingsAIAutomatic, settingsAIAutomaticNote
    case settingsAIMoveUp, settingsAIMoveDown, settingsAIStatusReady, settingsAIStatusOff, aiEngineUnavailable
    // Yapay zekâ önerilerini açarken ön koşul denetimi
    case settingsAIChecking, settingsAIRecheck, settingsAINotEnabled, aiCheckReady, aiCheckReadyModel, aiCheckDeviceNotEligible
    case aiCheckAppleOff, aiCheckModelNotReady, aiCheckAppleUnavailable, aiCheckServerOff, aiCheckNoModel, aiCheckModelMissing
    case aiCheckNoAnswer
    // Eski yedek hatırlatması
    case settingsBackupReminder, settingsBackupReminderOff, settingsBackupReminderDays, settingsBackupReminderNote, notifyStaleTitle
    case notifyStaleOne, notifyStaleNever, notifyStaleMany, staleDays, staleNever
    // Anlık görüntülerden geri yükleme
    case menuSnapshots, snapshotsTitle, snapshotsNone, snapshotsUp, snapshotsRoot, snapshotsEmptyFolder, snapshotsVersions
    case snapshotsRestoreVersion, snapshotsRestoreOriginal, snapshotsRestoreElsewhere, snapshotsRestoreNote, toastRestoreQueued
    case logRestoreFrom, snapshotsChooseFolder
    case snapshotsModeBrowse, snapshotsModeCompare, snapshotsSearchPrompt, snapshotsSearching, snapshotsSearchNone, snapshotsSearchHit
    case snapshotsSearchTruncated, snapshotsCompareOlder, snapshotsCompareNewer, snapshotsComparing, snapshotsCompareSame
    case snapshotsCompareAdded, snapshotsCompareChanged, snapshotsCompareRemoved, snapshotsCompareMore, snapshotsCompareNote
    case snapshotsCompareNeedsTwo, snapshotsQuickLook
    // Arşiv bütünlüğü
    case menuIntegrity, integrityTitle, integrityNote, integrityNever, integrityLast, integrityCheck, integrityChecking, integrityCancel
    case integrityFirst, integritySummary, integrityNoProblems, integrityCorrupted, integrityMissing, integrityUnreadable, integrityMore
    case integrityOnConnect, integrityFailed, notifyIntegrityTitle, notifyIntegrityProblems, notifyIntegrityIntact, notifyIntegrityFailed
    case integrityRepair, integrityRepairConfirmTitle, integrityRepairConfirmMessage, integrityRepairButton, integrityRepairing
    case integrityRepaired, integrityRepairNoCopy, integrityRepairFailed, integrityRepairChanged
    case optionEjectWhenDone, optionEjectWhenDoneNote, logEjected, logEjectFailed, notifyEjectedTitle, notifyEjectedBody, notifyEjectFailedTitle
    case notifyActionBackUpNow, notifyActionShow, notifyActionDecide, toastBackUpNowQueued
    // İzin uyarıları (bildirimler, Tam Disk Erişimi)
    case permissionLater, permissionOpenSettings, permissionNotificationsTitle, permissionNotificationsDenied
    case permissionNotificationsUnavailable, permissionNotificationsMoveApp, permissionFullDiskTitle, permissionFullDisk
    case permissionFullDiskNotice, settingsPermissionsSection, settingsPermissionsNote, settingsPermissionNotifications
    case settingsPermissionFullDisk, permissionStatusOn, permissionStatusOff, permissionStatusNotAsked, permissionStatusUnavailable
    case permissionStatusUnknown
    // İşleri ve ayarları başka bir Mac'e taşıma
    case menuExportSetup, menuImportSetup, exportSetupName, exportSetupFailed, toastSetupExported, setupImportTitle, setupImportNote
    case setupImportSettings, setupImportDone, setupImportFailedTitle, setupImportInvalid, setupImportNewer, setupImportTooLarge
    // Hedefin dolma tahmini
    case fillForecastTitle, fillForecastFree, fillForecastRange, fillForecastAtLeast, fillForecastNotFilling, fillForecastNotEnough
    case fillForecastNote, fillForecastRetention, notifyFillTitle, notifyFillBody
    // Tanılama raporu
    case menuDiagnostics, diagnosticsTitle, diagnosticsNote, diagnosticsSave, diagnosticsFileName
    // Günlük (konsol) penceresi
    case menuShowConsole, consoleTitle, consoleMessageCount, consoleAllMessages, consoleProblems, consoleSearchPrompt, consoleClear
    case consoleOpenInConsole, consoleEmptyTitle, consoleEmptyMessage, consoleSelectHint, consoleColumnTime, consoleColumnType
    case consoleColumnCategory, consoleColumnProcess, consoleColumnMessage, consoleLevelInfo, consoleLevelWarning, consoleLevelError
    case consoleCategoryApp, consoleCategoryEngine, consoleCategoryJob, consoleCategoryDisk, consoleCategoryIntegrity, consoleCategoryUpdate
    // Kuyruk bitince Mac'i uyut
    case menuSleepWhenDone, sleepArmedNotice, sleepCountdownNotice, sleepNowButton, notifySleepTitle, notifySleepBody
    // Son çalıştırmayı geri alma
    case menuUndoLastRun, undoConfirmTitle, undoSnapshotMessage, undoCreatedMessage, undoButton, undoFailed, logUndoneSnapshot
    case logUndoneCreated, toastUndone, undoMovedMessage, logUndoneMoved
    // Windows ve Office artıkları
    case optionExcludeWindows, optionExcludeWindowsNote
    // Çalıştırma raporu
    case menuSaveRunReport, reportFileName, reportSaveFailed, toastReportSaved, reportTitle, reportSource, reportDestination
    case reportStarted, reportFinished, reportResult, reportAdded, reportUpdated, reportDeleted, reportNoChanges, reportTruncated
    case reportTrashed, reportProblems
    // Karar sayfasında dosya başına ad
    case placementSuggestNames, placementNewName, placementNameNote, placementNamesSuggested, placementNoNameSuggestion
    // Arşivde arama
    case menuArchiveSearch, archiveSearchTitle, archiveSearchPrompt, archiveSearchContents, archiveSearchContentsNote
    case archiveSearchHint, archiveSearchSearching, archiveSearchNone, archiveSearchCount, archiveSearchLimited
    case archiveSearchMatchName, archiveSearchMatchContent, archiveSearchMatchPhoto, archiveSearchReveal, archiveSearchOpen
    case archiveSearchSaveCopy, archiveSearchTrash, archiveSearchTrashTitle, archiveSearchTrashMessage, archiveSearchTrashButton
    case archiveSearchOpenRefused, archiveSearchActionFailed, toastArchiveTrashed, toastArchiveCopied
    // Konum ölçütü
    case ruleAttrLocation
    // Klasör ağacı
    case menuSaveFolderTree, folderTreeTitle, folderTreeRoot, folderTreeTruncated, folderTreeFileName, toastFolderTreeSaved
    case folderTreeFailed
    // İçerikten alınan değerler (ad şablonunda {c:ad})
    case problemContentFieldName, problemContentFieldPattern, problemContentTokenInFolder, placementFields, placementFieldAdd
    case placementFieldRemove, placementFieldNamePrompt, placementFieldPatternPrompt, placementFieldNote, placementFieldSample
    case placementFieldSamplePrompt, placementFieldValue, placementFieldNoMatch, placementFieldsSummary, placementMissingFields
    case placementNameSheetTitle
    // Time Machine dışlaması
    case optionExcludeFromTimeMachine, optionExcludeFromTimeMachineNote, logTimeMachineExcluded, logTimeMachineExcludeFailed
    // Şifresiz hedef disk
    case destinationNotEncrypted, destinationNotEncryptedNote
    // Pil kritik seviyede
    case settingsPauseOnCriticalBattery, settingsPauseOnCriticalBatteryNote, logPausedForBattery, logResumedOnPower, batteryHoldNotice
    case notifyBatteryPausedTitle, notifyBatteryPausedBody
    // Düşük öncelikli disk G/Ç
    case settingsLowPriorityIO, settingsLowPriorityIONote, logLowPriority
    // Girişte aç
    case settingsOpenAtLogin, settingsOpenAtLoginNote, loginItemNeedsApproval, loginItemFailed
    // Yinelenen dosyalar
    case menuDuplicates, duplicatesTitle, duplicatesNote, duplicatesScanning, duplicatesNone, duplicatesSummary, duplicatesKeep
    case duplicatesGroup, duplicatesTrash, duplicatesTrashConfirm, duplicatesConfirmTitle, duplicatesConfirmMessage, duplicatesDone
    case duplicatesMore, duplicatesFailed
    // Rutinleri dışa ve içe aktarma
    case menuExportRoutines, menuImportRoutines, menuExportRoutine, exportRoutinesName, exportRoutinesFailed, toastRoutinesExported
    case importTitle, importNote, importSourceMissing, importDestinationMissing, importRoutes, importButton, importDone, importInvalid
    case importNewer, importTooLarge, importFailedTitle
    // Eşitleme rutini (iki yönlü)
    case logSyncPlanned, logSyncDirection, logSyncDone, routineKind, routineKindCopy, routineKindSync, routineKindSyncNote
    case syncFolderA, syncFolderB, conflictSyncUseA, conflictSyncUseB, conflictPolicyNewer, conflictPolicyUseA, conflictPolicyUseB
    case conflictSyncTitle, conflictSyncSubtitle, conflictSyncNote, syncPreviewToB, syncPreviewToA, syncPreviewDiffer, syncPreviewSummary
    case sendToRoutineSync, optionSyncPolicy, optionSyncPolicyNote
    case problemRuleEmpty, problemRuleRegex, problemRuleKind, problemRuleDepth
    case routineRoutePrefix, routineProblemName, routineProblemNoRoutes, routineProblemSource, routineProblemDestination
    case routineProblemSourceFolder
    case sidebarRoutines, menuNewRoutine, routineNewTitle, routineEditTitle, routineName, routineNamePlaceholder
    case routineRoute, routineAddRoute, routineRemoveRoute, routineRoutesNote, routineRules, routineOptions
    case ruleGroupLabel, ruleMatchAll, ruleMatchAny, ruleMatchNone, ruleAddCondition, ruleAddGroup, ruleRemoveGroup
    case ruleValuePlaceholder, ruleRegexPlaceholder, ruleRegexInvalid
    case ruleAttrName, ruleAttrExtension, ruleAttrFolder, ruleAttrPath, ruleAttrKind
    case ruleOpContains, ruleOpEquals, ruleOpBegins, ruleOpEnds, ruleOpRegex
    case fileKindImage, fileKindMovie, fileKindAudio, fileKindPDF, fileKindDocument, fileKindSpreadsheet, fileKindPresentation
    case fileKindText, fileKindSourceCode, fileKindArchive, fileKindApplication
    case rulesEverything, rulesAnd, rulesOr, rulesNoneOf, ruleConditionFormat
    case routineSave, routineSaveRun, routineRun, routineCopyName, routineDelete
    case routineDeleteConfirmTitle, routineDeleteConfirmMessage, routineDeleteButton
    case routineLastRun, routineNeverRun, routineJobs, routineNoJobs, toastRoutineQueued, toastRoutineSaved, logRoutineRun
    case routineSampleTitle, routineSamplePlaceholder, routineSampleMatches, routineSampleNoMatch, routineSampleNote
    case detailRoutine, detailRules
    case intentRunRoutineTitle, intentRunRoutineDescription, intentRoutineParameter, intentRoutineTypeName
    case intentRoutineQueued, intentRoutineNotFound, shortcutRunRoutine, menuBarRoutines, routineMore
    // Gelişmiş ölçütler
    case ruleAdvancedSection, ruleAttrSize, ruleAttrModified, ruleAttrCreated, ruleAttrAdded, ruleAttrTag, ruleAttrHidden
    case ruleAttrDepth, ruleAttrCaptureDate, ruleAttrResolution, ruleAttrDuration, ruleAttrCamera, ruleAttrContent
    case ruleOpOneOf, ruleOpGreater, ruleOpLess, ruleOpAtMost, ruleOpAtLeast, ruleOpWithinLast, ruleOpNotWithinLast
    case ruleOpBefore, ruleOpAfter, ruleOpHidden, ruleOpVisible, ruleOpHasTag, ruleOpNoTag
    case unitKB, unitMB, unitGB, unitTB, unitSeconds, unitMinutes, unitHours, unitDays, unitWeeks, unitMonths, unitYears
    case unitPixels, unitLevels
    case ruleListPlaceholder, ruleTagPlaceholder, ruleConditionFormatNoValue, routineSampleAdvancedNote
    case problemRuleNumber, problemRuleDate, ruleWithinFormat, ruleNotWithinFormat
    // Aynı adlı dosyalar
    case logAwaitingDecision, logConflictsResolved, logKeptBoth, logKeepBothFailed, logKeptBothRenamed, resultAwaitingDecision
    case conflictIncomingFolder, conflictKeepBothFolderNote
    case statusAwaitingDecision, conflictTitle, conflictSubtitle, conflictIdenticalCount, conflictApplyAll
    case conflictReplace, conflictKeepBoth, conflictSkip, conflictFile, conflictDecisionColumn, conflictIdentical
    case conflictTruncated, conflictRememberJob, conflictRememberRoutine, conflictLater, conflictContinue, conflictKeepBothNote
    case menuResolveConflicts, notifyDecisionTitle, notifyDecisionBody, optionConflictPolicy, optionConflictPolicyNote
    case conflictPolicyAsk, conflictPolicyReplace, conflictPolicyKeepBoth, conflictPolicySkip, logConflictsDecided, menuBarAwaiting
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
        case .awaitingDecision:
            return format(result.detail == JobResult.placementsDetail ? .resultAwaitingPlacement : .resultAwaitingDecision, result.noteCount)
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
        case .sandboxUnavailable: return string(.resultSandboxUnavailable, language: code)
        case .unsupported: return string(.resultUnsupported, language: code)
        case .ioError: return string(.resultIOError, language: code)
        case .verificationFailed:
            if let count = result.differenceCount { return format(.resultVerificationFailed, count) }
            return string(.resultVerificationIncomplete, language: code)
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
