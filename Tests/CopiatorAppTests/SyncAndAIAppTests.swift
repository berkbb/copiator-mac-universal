// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Uygulama testlerinin sahte öneri modeli.
struct AppFakeSuggestionModel: SuggestionModel {
    var isAvailable: Bool
    var answer = ""
    func respond(instructions: String, prompt: String) async throws -> String { answer }
}

/// Eşitleme rutini, yapay zekâ önerileri ve yeni sayfalar: gerçek kuyruk ve rsync ile.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct SyncAndAIAppTests {
    /// Eşitleme rutini kuyruktan çalışır: iki yanda farklı dosya sorulur, "B kazansın" hatırlanır, eksikler iki yöne
    /// kopyalanır, hiçbir şey silinmez. Eşitleme rutinine seçili öğe gönderilemez.
    @Test func syncRoutineAsksRemembersAndSyncsBothWays() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        try fixture.write("A/yalniz-a.txt", "a")
        try fixture.write("A/ortak.txt", "A sürümü")
        try fixture.write("B/yalniz-b.txt", "b")
        try fixture.write("B/ortak.txt", "B sürümü, daha uzun")
        let routine = Routine(name: "Eşitle", kind: .sync, routes: [RoutineRoute(source: fixture.url("A"), destination: fixture.url("B"))])
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.runRoutine(routine.id) == nil)
        await model.waitUntilIdle()
        let job = try #require(model.jobs(for: routine.id).first)
        #expect(job.kind == .sync && job.isAwaitingDecision)
        #expect(job.pendingConflicts?.items.map(\.path) == ["ortak.txt"])
        #expect(fixture.read("B/yalniz-a.txt") == nil)

        model.resolveConflicts(job.id, resolution: ConflictResolution(others: .reverse), remember: .reverse)
        await model.waitUntilIdle()
        #expect(model.job(job.id)?.status == .finished, "\(model.job(job.id)?.log.suffix(5) ?? [])")
        #expect(fixture.read("A/ortak.txt") == "B sürümü, daha uzun" && fixture.read("B/ortak.txt") == "B sürümü, daha uzun")
        #expect(fixture.read("B/yalniz-a.txt") == "a" && fixture.read("A/yalniz-b.txt") == "b")
        #expect(model.routine(routine.id)?.options.conflictPolicy == .reverse)

        #expect(model.runRoutine(routine.id, on: [fixture.url("A/yalniz-a.txt")]) == fixture.settings.t(.sendToRoutineSync))
        model.alert = nil

        let settings = fixture.settings
        settings.language = .tr
        #expect(settings.title(ConflictPolicy.replace, kind: .sync) == "A kazansın" && settings.title(ConflictPolicy.newer, kind: .sync) == "Yenisi kazansın")
        #expect(settings.title(ConflictDecision.reverse, kind: .sync) == "B'dekini A'ya yaz" && settings.title(ConflictDecision.replace) == "Değiştir")
        #expect(ConflictDecision.reverse.number(for: .sync) == 2 && ConflictDecision.skip.number(for: .rsync) == 3)
    }

    /// Yapay zekâ önerileri yalnızca ayar açıkken (varsayılan kapalı) ve bu Mac'te model varken sunulur.
    @Test func aiSuggestionsFollowTheSettingAndTheModel() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.suggestionModel = AppFakeSuggestionModel(isAvailable: true)
        #expect(!fixture.settings.aiSuggestions && !model.canSuggestWithAI)
        fixture.settings.aiSuggestions = true
        #expect(model.canSuggestWithAI)
        fixture.settings.aiSuggestions = false
        #expect(!model.canSuggestWithAI)
        fixture.settings.aiSuggestions = true
        model.suggestionModel = AppFakeSuggestionModel(isAvailable: false)
        #expect(!model.canSuggestWithAI)
        // Öneri düğmelerinin yanındaki uyarı: model en iyi İngilizcede çalışır.
        let settings = fixture.settings
        settings.language = .tr
        #expect(settings.t(.aiLanguageWarning).contains("İngilizce"))
        settings.language = .en
        #expect(settings.t(.aiLanguageWarning).contains("English"))
        settings.language = .ro
        #expect(settings.t(.aiLanguageWarning).contains("engleză"))
    }

    /// Ekran dışı çizim; COPIATOR_SNAPSHOT_DIR verilirse PNG olarak da yazılır.
    private func render(_ view: AnyView, _ size: NSSize, _ name: String) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.layoutIfNeeded()
        window.displayIfNeeded()
        spinRunLoop(0.3)
        if let directory = ProcessInfo.processInfo.environment["COPIATOR_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }),
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.close()
    }

    /// "Klasörü sor" rutini kuyruktan: hiçbir şey kopyalanmadan klasör önerilir ve karar sayfası açılır; seçim ve "Hatırla"
    /// ile seçilen klasöre hedef numarasıyla adlandırılarak kopyalanır ve rota klasörü öğrenir; benzer adlı sonraki dosya
    /// sorulmadan gider.
    @Test func askFolderRoutineAsksCopiesAndRemembers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        model.suggestionModel = AppFakeSuggestionModel(isAvailable: true, answer: "1")
        fixture.settings.language = .tr
        try fixture.write("Faturalar/enerjisa ekim.txt", "ekim")
        for folder in ["Hedef/Elektrik (123456789)", "Hedef/Su (987654321)"] {
            try FileManager.default.createDirectory(at: fixture.url(folder), withIntermediateDirectories: true)
        }
        let placement = RoutePlacement(nameTemplate: "{targetNumber}_{name}", askFolder: true)
        let routine = Routine(name: "Faturalar", routes: [RoutineRoute(source: fixture.url("Faturalar"), destination: fixture.url("Hedef"), placement: placement)],
                              options: CopyOptions(conflictPolicy: .skip))
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.runRoutine(routine.id) == nil)
        await model.waitUntilIdle()
        let job = try #require(model.jobs(for: routine.id).first)
        #expect(job.isAwaitingDecision && job.pendingPlacements?.items.first?.suggestions.first == "Elektrik (123456789)")
        #expect(model.conflictPrompt?.id == job.id && fixture.read("Hedef/Elektrik (123456789)/123456789_enerjisa ekim.txt") == nil)
        let settings = fixture.settings
        #expect(settings.result(try #require(job.result)) == "Karar bekleniyor: 1 dosyanın hedefteki klasörü seçilmeli")
        #expect(fixture.notifications.last?.1 == settings.t(.notifyPlacementBody, "Faturalar", 1))
        render(AnyView(ConflictSheet(prompt: ConflictPrompt(id: job.id)).environment(model).environment(fixture.settings)),
               NSSize(width: 720, height: 540), "placement-decision")

        model.resolvePlacements(job.id, resolution: PlacementResolution(folders: ["enerjisa ekim.txt": "Elektrik (123456789)"]),
                                remember: ["enerjisa ekim.txt": "Elektrik (123456789)"])
        #expect(model.conflictPrompt == nil)
        await model.waitUntilIdle()
        #expect(model.job(job.id)?.status == .finished, "\(model.job(job.id)?.log.suffix(5) ?? [])")
        #expect(fixture.read("Hedef/Elektrik (123456789)/123456789_enerjisa ekim.txt") == "ekim")
        #expect(model.routine(routine.id)?.routes.first?.placement.learnedFolders == ["enerjisa.txt": "Elektrik (123456789)"])

        try fixture.write("Faturalar/Enerjisa Kasım.txt", "kasım")
        #expect(model.runRoutine(routine.id) == nil)
        await model.waitUntilIdle()
        #expect(model.jobs(for: routine.id).allSatisfy { $0.status == .finished }, "\(model.jobs(for: routine.id).map { $0.log.suffix(4) })")
        #expect(fixture.read("Hedef/Elektrik (123456789)/123456789_Enerjisa Kasım.txt") == "kasım")
    }

    /// Yerel sunucu sağlayıcısı: sunucu yanıt vermezse öneri yok; listedeki model seçilince öneriler açılır ve kaynak adı
    /// görünür, listede olmayan (silinmiş) model kullanılmaz; dil uyarısı yalnızca Apple Intelligence içindir. Ayarlar
    /// kaydedilir. Testte sunucu portu boş bir porttur (gerçek Ollama'ya dokunulmaz).
    @Test func localProviderFollowsTheServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        model.localServerPorts = [.ollama: 1, .lmStudio: 1]
        settings.aiSuggestions = true
        settings.aiProvider = .ollama
        await model.refreshLocalModels()
        #expect(!model.runningServers.contains(.ollama) && !model.canSuggestWithAI && settings.aiOllamaModel.isEmpty)

        model.localModels[.ollama] = ["yerel:1b"]
        model.runningServers.insert(.ollama)
        settings.aiOllamaModel = "yerel:1b"
        model.updateSuggestionModel()
        #expect(model.canSuggestWithAI && model.suggestionSourceName == "Ollama · yerel:1b")
        #expect((model.suggestionModel as? LocalServerSuggestionModel)?.server == .ollama)
        settings.aiOllamaModel = "silindi:1b"
        model.updateSuggestionModel()
        #expect(!model.canSuggestWithAI)
        render(AnyView(SettingsView().environment(model).environment(settings)), NSSize(width: 580, height: 900), "settings-ollama")

        settings.aiProvider = .lmStudio
        await model.refreshLocalModels()
        #expect(!model.canSuggestWithAI && (model.suggestionModel as? LocalServerSuggestionModel)?.server == .lmStudio)
        settings.aiProvider = .apple
        model.updateSuggestionModel()
        #expect(model.suggestionModel is OnDeviceSuggestionModel && model.suggestionSourceName == "Apple Intelligence")
        #expect(AILanguageWarning.applies(to: [.apple]) && !AILanguageWarning.applies(to: [.ollama, .lmStudio]))
        #expect(fixture.defaults.string(forKey: "aiProvider") == "apple" && fixture.defaults.string(forKey: "aiOllamaModel") == "silindi:1b")

        // Otomatik: sıradaki modellerin zinciri; kapatılan model çıkar, sıra değişir; yerel model hazırsa Apple kapalıyken de
        // öneri verilir. Erişilemeyen sunucu hata göstermez, yalnızca hazır sayılmaz.
        settings.aiProvider = .automatic
        await model.refreshLocalModels()
        #expect(model.alert == nil && !model.isReady(.lmStudio))
        #expect((model.suggestionModel as? FallbackSuggestionModel)?.members.map(\.name) == ["Apple Intelligence", "Ollama · silindi:1b", "LM Studio"])
        #expect(AILanguageWarning.applies(to: settings.activeProviders))
        settings.aiAutomaticOrder = [.lmStudio, .ollama, .apple]
        settings.aiAutomaticOff = [.apple]
        model.localModels[.ollama] = ["yerel:1b"]
        settings.aiOllamaModel = "yerel:1b"
        model.updateSuggestionModel()
        #expect((model.suggestionModel as? FallbackSuggestionModel)?.members.map(\.name) == ["LM Studio", "Ollama · yerel:1b"])
        #expect(model.canSuggestWithAI && model.isReady(.ollama) && !AILanguageWarning.applies(to: settings.activeProviders))
        #expect(model.suggestionSourceName == settings.t(.settingsAIAutomatic))
        render(AnyView(SettingsView().environment(model).environment(settings)), NSSize(width: 580, height: 1000), "settings-automatic")
        #expect(fixture.defaults.stringArray(forKey: "aiAutomaticOrder") == ["lmStudio", "ollama", "apple"])
        #expect(fixture.defaults.stringArray(forKey: "aiAutomaticOff") == ["apple"])
        let reopened = AppSettings(defaults: fixture.defaults, bundle: resourcesBundle)
        #expect(reopened.aiProvider == .automatic && reopened.automaticProviders == [.lmStudio, .ollama])
    }

    /// Yapay zekâ önerileri isteğe bağlıdır (varsayılan kapalı). Açarken ön koşullar denetlenir: hiçbir model hazır değilse
    /// kapalı kalır ve her sağlayıcının sorunu listelenir; hazır bir model varsa açılır. Kapatınca sonuçlar silinir.
    /// Testte yerel sunucu portları boştur (gerçek Ollama'ya dokunulmaz).
    @Test func aiSuggestionsAreOptInAndCheckedWhenTurnedOn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        settings.language = .tr
        #expect(!settings.aiSuggestions)
        model.localServerPorts = [.ollama: 1, .lmStudio: 1]
        model.appleProblem = { .appleIntelligenceOff }
        settings.aiProvider = .automatic
        #expect(await model.setAISuggestions(true) == false)
        #expect(!settings.aiSuggestions && !model.isCheckingAI)
        #expect(model.aiChecks.map(\.problem) == [.appleIntelligenceOff, .serverNotRunning, .serverNotRunning])
        #expect(settings.checkText(model.aiChecks[1]) == "Ollama: 127.0.0.1:11434 adresinde çalışmıyor; uygulamayı açın.")
        render(AnyView(SettingsView().environment(model).environment(settings)), NSSize(width: 580, height: 1000), "settings-ai-not-ready")

        model.appleProblem = { nil }
        model.appleTestModel = AppFakeSuggestionModel(isAvailable: true, answer: "OK")
        #expect(await model.setAISuggestions(true))
        #expect(settings.aiSuggestions && model.aiChecks.first == AIPrerequisites.Check(provider: .apple))
        #expect(settings.checkText(model.aiChecks[0]) == "Apple Intelligence: hazır")
        render(AnyView(SettingsView().environment(model).environment(settings)), NSSize(width: 580, height: 1100), "settings-ai-ready")

        await model.setAISuggestions(false)
        #expect(!settings.aiSuggestions && model.aiChecks.isEmpty)
        let reopened = AppSettings(defaults: fixture.defaults, bundle: resourcesBundle)
        #expect(!reopened.aiSuggestions)
    }

    /// Eski yedek hatırlatması: erişilebilen hedefteki eski yedek için bildirim; aynı öğe için günde en çok bir kez, ertesi gün
    /// yeniden; kapalıyken hiç. Hiçbir iş kendiliğinden başlamaz.
    @Test func staleBackupsAreRemindedOncePerDay() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        settings.language = .tr
        let now = Date()
        var job = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), status: .finished)
        job.history = [JobRun(startedAt: now.addingTimeInterval(-40 * 86_400 - 60), finishedAt: now.addingTimeInterval(-40 * 86_400),
                              result: JobResult(kind: .succeeded))]
        let id = job.id
        try fixture.store.save([job])
        let model = fixture.relaunch()
        #expect(settings.backupReminderDays == 30)
        model.remindStaleBackups(on: nil, now: now)
        #expect(fixture.notifications.count == 1)
        #expect(fixture.notifications.last?.0 == "Yedek eskidi" && fixture.notifications.last?.1 == "“Kaynak”: son başarılı yedek 40 gün önce alındı.")
        model.remindStaleBackups(on: nil, now: now.addingTimeInterval(3_600))
        #expect(fixture.notifications.count == 1)
        model.remindStaleBackups(on: nil, now: now.addingTimeInterval(90_000))
        #expect(fixture.notifications.count == 2)
        settings.backupReminderDays = 0
        model.remindStaleBackups(on: nil, now: now.addingTimeInterval(200_000))
        #expect(fixture.notifications.count == 2 && model.job(id)?.status == .finished)
        #expect(AppSettings(defaults: fixture.defaults, bundle: resourcesBundle).backupRemindedAt[id.uuidString] != nil)
    }

    /// Yeni sayfalar ekran dışı çizilir: temizleme aracı, eşitleme rutini düzenleyicisi, yapay zekâ düğmeli yerleşim.
    @Test func newSheetsRender() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        model.suggestionModel = AppFakeSuggestionModel(isAvailable: true, answer: "El_{month}_{yy}")
        render(AnyView(CleanupSheet(request: CleanupRequest(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"))).environment(settings)),
               NSSize(width: 620, height: 600), "cleanup")
        let sync = Routine(name: "Özel eşitleme", kind: .sync, routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"))],
                           options: CopyOptions(conflictPolicy: .newer))
        render(AnyView(RoutineEditorSheet(request: RoutineEditorRequest(routine: sync, isExisting: true)).environment(model).environment(settings)),
               NSSize(width: 680, height: 900), "routine-editor-sync")
        let placed = Routine(name: "Faturalar", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
                                                                      placement: RoutePlacement(folderTemplate: "{year}", nameFixes: [NameFix.presets[0]], askFolder: true, learnedFolders: ["enerjisa.pdf": "Elektrik"]))])
        render(AnyView(RoutineEditorSheet(request: RoutineEditorRequest(routine: placed, isExisting: true)).environment(model).environment(settings)),
               NSSize(width: 680, height: 1100), "routine-editor-ai")
    }
}
