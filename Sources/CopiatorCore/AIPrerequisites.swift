// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Yapay zekâ önerileri açılırken ön koşulların denetimi. Apple Intelligence'ta sistem durumu (Mac uygun mu, açık mı,
/// model indi mi), yerel sunucuda sunucunun çalışması, yerel sohbet modeli (bulut ve gömme modelleri sayılmaz) ve seçili
/// model; ikisinde de kısa bir deneme sorusunun yanıtlanması gerekir. Hiçbir denetim hata atmaz; sonuç her sağlayıcı için
/// "hazır" ya da bir sorundur.
public enum AIPrerequisites {
    public enum Problem: Equatable, Sendable {
        /// Bu Mac Apple Intelligence'ı desteklemiyor.
        case deviceNotEligible
        /// Apple Intelligence Sistem Ayarları'nda kapalı.
        case appleIntelligenceOff
        /// Model henüz hazır değil (indiriliyor olabilir).
        case modelNotReady
        /// Apple Intelligence başka bir nedenle kullanılamıyor.
        case appleUnavailable
        /// Yerel sunucu 127.0.0.1'de yanıt vermiyor.
        case serverNotRunning
        /// Sunucuda yerel sohbet modeli yok.
        case noLocalModel
        /// Seçili model sunucuda yok.
        case modelMissing(String)
        /// Deneme sorusuna yanıt gelmedi (hata ya da zaman aşımı).
        case noAnswer
    }

    public struct Check: Equatable, Sendable {
        public var provider: SuggestionProvider
        /// Hazırsa kullanılan model (yerel sunucuda model adı; Apple'da nil).
        public var model: String?
        public var problem: Problem?

        public var isReady: Bool { problem == nil }

        public init(provider: SuggestionProvider, model: String? = nil, problem: Problem? = nil) {
            self.provider = provider
            self.model = model
            self.problem = problem
        }
    }

    /// Deneme sorusunun en uzun süresi (yerel sunucuda model ilk kez belleğe yüklenirken uzun sürebilir).
    public static let testTimeout: Duration = .seconds(90)

    /// Apple Intelligence'ın sistem durumu; kullanılabiliyorsa nil.
    public static func appleProblem() -> Problem? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .appleUnavailable
        }
        #else
        return .deviceNotEligible
        #endif
    }

    /// Apple Intelligence: sistem durumu, ardından deneme sorusu.
    public static func checkApple(problem: Problem?, model: any SuggestionModel) async -> Check {
        if let problem { return Check(provider: .apple, problem: problem) }
        return await answers(model) ? Check(provider: .apple) : Check(provider: .apple, problem: .noAnswer)
    }

    /// Yerel sunucu: çalışıyor mu, yerel sohbet modeli var mı, seçili model (boşsa ilk model) yerinde mi, deneme sorusu
    /// yanıtlanıyor mu.
    /// - Parameter port: Testler kendi sunucularının portunu verir; adres her zaman 127.0.0.1'dir.
    public static func checkServer(_ server: LocalModelServer, selected: String, port: Int? = nil) async -> Check {
        let provider: SuggestionProvider = server == .ollama ? .ollama : .lmStudio
        guard let models = await server.models(port: port) else { return Check(provider: provider, problem: .serverNotRunning) }
        guard let first = models.first else { return Check(provider: provider, problem: .noLocalModel) }
        let name = selected.isEmpty ? first : selected
        guard models.contains(name) else { return Check(provider: provider, problem: .modelMissing(name)) }
        let model = LocalServerSuggestionModel(server: server, model: name, isAvailable: true, port: port)
        return await answers(model) ? Check(provider: provider, model: name) : Check(provider: provider, model: name, problem: .noAnswer)
    }

    /// Kısa bir deneme sorusu boş olmayan bir yanıt alıyor mu (zaman aşımıyla).
    static func answers(_ model: any SuggestionModel) async -> Bool {
        let answer = await Suggestions.$timeout.withValue(testTimeout) {
            await Suggestions.reply(model, instructions: "You check that a language model works. Answer with one word.", prompt: "Say OK.")
        }
        return !(answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
