// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Öneri modelinin sağlayıcısı: Apple Intelligence, bu Mac'te çalışan yerel bir model sunucusu ya da "Otomatik" (seçilen
/// sırayla, ilk yanıt verebilen; bkz. `FallbackSuggestionModel`).
public enum SuggestionProvider: String, CaseIterable, Identifiable, Sendable {
    case automatic, apple, ollama, lmStudio

    public var id: String { rawValue }
    /// Gerçek sağlayıcılar (Otomatik dışındakiler), varsayılan sırayla.
    public static let models: [SuggestionProvider] = [.apple, .ollama, .lmStudio]

    /// Ürün adı (çevrilmez; Otomatik için boş, arayüz kendi metnini yazar).
    public var displayName: String {
        switch self {
        case .automatic: ""
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }
    /// Yerel sunucu (Apple Intelligence ve Otomatik için nil).
    public var server: LocalModelServer? {
        switch self {
        case .automatic, .apple: nil
        case .ollama: .ollama
        case .lmStudio: .lmStudio
        }
    }

    /// Kaydedilmiş sıradan geçerli bir sıra: her gerçek sağlayıcı bir kez; bilinmeyenler atılır, eksikler sona eklenir.
    public static func order(_ raw: [String]) -> [SuggestionProvider] {
        var order: [SuggestionProvider] = []
        for value in raw {
            if let provider = SuggestionProvider(rawValue: value), provider != .automatic, !order.contains(provider) { order.append(provider) }
        }
        return order + models.filter { !order.contains($0) }
    }
}

/// "Otomatik": modeller sırayla denenir. Kullanılabilir ilk model sorulur; erişilemezse, hata verirse ya da yanıtı geçersizse
/// (bkz. `Suggestions.ask`) sıradaki denenir. Hiçbiri yanıt veremezse öneri yoktur: hata gösterilmez, kural tabanlı öneri
/// kalır. Son geçerli yanıtı veren model `lastSource`dur.
public final class FallbackSuggestionModel: SuggestionModel, @unchecked Sendable {
    public let members: [(name: String, model: any SuggestionModel)]
    private let lock = NSLock()
    private var answered: String?

    public init(_ members: [(name: String, model: any SuggestionModel)]) {
        self.members = members
    }

    public var isAvailable: Bool { members.contains { $0.model.isAvailable } }

    /// Son geçerli yanıtı veren modelin adı.
    public var lastSource: String? { lock.withLock { answered } }

    func record(_ name: String) { lock.withLock { answered = name } }

    /// Doğrulamasız kullanım: kullanılabilir ilk modelin yanıtı; hepsi başarısızsa hata.
    public func respond(instructions: String, prompt: String) async throws -> String {
        for member in members where member.model.isAvailable {
            if let answer = try? await member.model.respond(instructions: instructions, prompt: prompt) {
                record(member.name)
                return answer
            }
        }
        throw LocalModelServer.Failure.unavailable
    }
}

/// Bu Mac'te çalışan yerel model sunucusu (Ollama, LM Studio). Adres sabittir: yalnızca 127.0.0.1 ve sunucunun bilinen
/// portu (kullanıcı başka bir adres giremez); vekil sunucu kullanılmaz, yönlendirme izlenmez, önbellek ve çerez tutulmaz.
/// Ollama'nın bulut modelleri (istekleri ollama.com'a iletenler) listelenmez ve kullanılmaz. Böylece dosya adları ve
/// içerikler Mac'ten çıkmaz.
public enum LocalModelServer: String, CaseIterable, Identifiable, Sendable {
    case ollama, lmStudio

    public var id: String { rawValue }
    /// Ürün adı (çevrilmez).
    public var displayName: String { self == .ollama ? "Ollama" : "LM Studio" }
    public var port: Int { self == .ollama ? 11434 : 1234 }
    var modelsPath: String { self == .ollama ? "/api/tags" : "/v1/models" }
    var chatPath: String { self == .ollama ? "/api/chat" : "/v1/chat/completions" }

    /// Yanıtın en çok boyutu; daha büyüğü reddedilir.
    static let maxResponse = 4_000_000

    public enum Failure: Error, Equatable, Sendable {
        case unavailable, badResponse
    }

    /// Sunucudaki yerel sohbet modelleri (adlarına göre sıralı); sunucu çalışmıyorsa nil.
    /// - Parameter port: Testler kendi sunucularının portunu verir.
    public func models(port: Int? = nil) async -> [String]? {
        guard let data = try? await Self.request(modelsPath, port: port ?? self.port, body: nil, timeout: 3) else { return nil }
        return self == .ollama ? Self.ollamaModels(data) : Self.openAIModels(data)
    }

    /// Ollama `/api/tags`: bulut modelleri (`remote_host`, `remote_model` ya da "…-cloud", "…:cloud" adlı) ve sohbet
    /// yeteneği olmayanlar (gömme modelleri) atılır.
    static func ollamaModels(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry -> String? in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty else { return nil }
            if entry["remote_host"] != nil || entry["remote_model"] != nil || isCloud(name) { return nil }
            if let capabilities = entry["capabilities"] as? [String], !capabilities.contains("completion") { return nil }
            return name
        }.sorted()
    }

    /// LM Studio `/v1/models` (OpenAI biçimi): gömme modelleri atılır.
    static func openAIModels(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry -> String? in
            guard let id = entry["id"] as? String, !id.isEmpty, !id.lowercased().contains("embed") else { return nil }
            return id
        }.sorted()
    }

    /// Ollama'nın bulut modeli adı ("gpt-oss:120b-cloud", "nemotron-3-ultra:cloud").
    static func isCloud(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix("-cloud") || lowered.hasSuffix(":cloud") || lowered.contains("-cloud:")
    }

    static func ollamaAnswer(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    static func openAIAnswer(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any]
        else { return nil }
        return message["content"] as? String
    }

    /// Düşünen modellerin "<think>…</think>" bölümü atılır (yanıt yalnızca sonuçtur).
    static func withoutThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"), let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 127.0.0.1'e istek: vekil sunucusuz, yönlendirmesiz; yalnızca 200 ve en çok `maxResponse` bayt kabul edilir.
    static func request(_ path: String, port: Int, body: Data?, timeout: TimeInterval) async throws -> Data {
        guard (1...65_535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw Failure.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "127.0.0.1",
              data.count <= maxResponse else { throw Failure.badResponse }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Yönlendirmeler izlenmez: yerel sunucu isteği başka bir adrese (ör. internete) aktaramaz.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

/// Yerel model sunucusundaki bir modelle öneri (Ollama `/api/chat`, LM Studio `/v1/chat/completions`).
public struct LocalServerSuggestionModel: SuggestionModel {
    public var server: LocalModelServer
    public var model: String
    /// Model son listede vardı (sunucu çalışıyor ve model yerel).
    public var isAvailable: Bool
    var port: Int

    /// - Parameter port: Testler kendi sunucularının portunu verir; adres her zaman 127.0.0.1'dir.
    public init(server: LocalModelServer, model: String, isAvailable: Bool, port: Int? = nil) {
        self.server = server
        self.model = model
        self.isAvailable = isAvailable && !model.isEmpty && !LocalModelServer.isCloud(model)
        self.port = port ?? server.port
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        guard isAvailable else { throw LocalModelServer.Failure.unavailable }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
            "stream": false,
        ]
        // Rastgelelik yok: aynı soru aynı yanıtı alır.
        if server == .ollama { body["options"] = ["temperature": 0] } else { body["temperature"] = 0 }
        // Geçersiz bir nesne JSONSerialization'da hata değil çökme olurdu: önce denetlenir.
        guard JSONSerialization.isValidJSONObject(body) else { throw LocalModelServer.Failure.badResponse }
        let data = try await LocalModelServer.request(server.chatPath, port: port, body: JSONSerialization.data(withJSONObject: body),
                                                      timeout: 60)
        guard let answer = server == .ollama ? LocalModelServer.ollamaAnswer(data) : LocalModelServer.openAIAnswer(data)
        else { throw LocalModelServer.Failure.badResponse }
        return LocalModelServer.withoutThinking(answer)
    }
}
