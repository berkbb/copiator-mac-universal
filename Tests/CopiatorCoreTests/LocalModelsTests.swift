// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Testing
@testable import CopiatorCore

/// 127.0.0.1'de rastgele bir portta çalışan sahte model sunucusu (Ollama ve LM Studio uç noktaları). Gelen istekleri
/// kaydeder; yanıtı testin verdiği işlev üretir.
final class FakeModelServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    typealias Response = (status: Int, headers: [String: String], body: Data)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeModelServer")
    private let lock = NSLock()
    private var received: [Request] = []
    private let respond: @Sendable (Request) -> Response
    private(set) var port = 0

    init(respond: @escaping @Sendable (Request) -> Response) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = Int(listener.port?.rawValue ?? 0)
    }

    var requests: [Request] { lock.withLock { received } }

    func stop() { listener.cancel() }

    static func json(_ object: Any, status: Int = 200) -> Response {
        (status, [:], (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                lock.withLock { received.append(request) }
                let response = respond(request)
                var head = "HTTP/1.1 \(response.status) Test\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
                connection.send(content: Data((head + "\r\n").utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }
}

/// Model listeleri: Ollama'nın bulut modelleri (`remote_host`, "…-cloud", "…:cloud") ve sohbet yeteneği olmayanlar, LM
/// Studio'nun gömme modelleri atılır; yanıtlardan içerik alınır, "<think>" bölümleri silinir.
@Test func localModelListsDropCloudAndEmbeddingModels() throws {
    let ollama = try JSONSerialization.data(withJSONObject: ["models": [
        ["name": "gemma4:e2b", "capabilities": ["completion", "vision"]],
        ["name": "nemotron-3-nano:30b-cloud", "remote_model": "nemotron-3-nano:30b", "remote_host": "https://ollama.com:443"],
        ["name": "nemotron-3-ultra:cloud"],
        ["name": "gpt-oss:120b-cloud"],
        ["name": "uzak", "remote_host": "https://example.com"],
        ["name": "nomic-embed-text", "capabilities": ["embedding"]],
        ["model": "llama3.2:3b"],
    ]])
    #expect(LocalModelServer.ollamaModels(ollama) == ["gemma4:e2b", "llama3.2:3b"])
    let lmStudio = try JSONSerialization.data(withJSONObject: ["data": [["id": "qwen3-8b"], ["id": "text-embedding-nomic-embed-text-v1.5"], ["id": ""]]])
    #expect(LocalModelServer.openAIModels(lmStudio) == ["qwen3-8b"])
    #expect(LocalModelServer.ollamaModels(Data("bozuk".utf8)).isEmpty && LocalModelServer.openAIModels(Data()).isEmpty)
    #expect(LocalModelServer.isCloud("x:cloud") && LocalModelServer.isCloud("X-CLOUD") && LocalModelServer.isCloud("a-cloud:latest"))
    #expect(!LocalModelServer.isCloud("cloudy:7b"))
    #expect(!LocalServerSuggestionModel(server: .ollama, model: "gpt-oss:120b-cloud", isAvailable: true).isAvailable)
    #expect(!LocalServerSuggestionModel(server: .ollama, model: "", isAvailable: true).isAvailable)

    #expect(LocalModelServer.ollamaAnswer(try JSONSerialization.data(withJSONObject: ["message": ["content": "2, 1"]])) == "2, 1")
    #expect(LocalModelServer.openAIAnswer(try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "1"]]]])) == "1")
    #expect(LocalModelServer.openAIAnswer(Data("{}".utf8)) == nil)
    #expect(LocalModelServer.withoutThinking("<think>uzun düşünce</think>\n 3, 1 ") == "3, 1")
    #expect(LocalModelServer.withoutThinking("a<think>x</think>b<think>y</think>c") == "abc")
    #expect(LocalModelServer.withoutThinking("<think>bitmedi") == "<think>bitmedi")
}

/// Sahte sunucuyla gerçek HTTP: model listesi ve sohbet istekleri doğru uç noktaya, doğru gövdeyle gider; yanıt alınır.
/// Yönlendirme izlenmez (istek başka bir adrese aktarılamaz), 200 dışı yanıt ve kapalı port hata verir.
@Test func localServersAreAskedOnLoopbackOnly() async throws {
    let server = try FakeModelServer { request in
        switch (request.method, request.path) {
        case ("GET", "/api/tags"):
            return FakeModelServer.json(["models": [["name": "yerel:1b", "capabilities": ["completion"]], ["name": "uzak:cloud"]]])
        case ("POST", "/api/chat"):
            return FakeModelServer.json(["message": ["role": "assistant", "content": "<think>hmm</think>2, 1"]])
        case ("GET", "/v1/models"):
            return FakeModelServer.json(["data": [["id": "qwen3-8b"]]])
        case ("POST", "/v1/chat/completions"):
            return FakeModelServer.json(["choices": [["message": ["content": "NEW: Faturalar/Su"]]]])
        case ("GET", "/yonlendir"):
            // İzlenseydi aynı sunucudaki 200 yanıtı alınır ve istek başarılı olurdu.
            return (302, ["Location": "/disari"], Data())
        case ("GET", "/disari"):
            return FakeModelServer.json(["models": []])
        default:
            return FakeModelServer.json(["error": "yok"], status: 500)
        }
    }
    defer { server.stop() }
    #expect(server.port > 0)

    #expect(await LocalModelServer.ollama.models(port: server.port) == ["yerel:1b"])
    #expect(await LocalModelServer.lmStudio.models(port: server.port) == ["qwen3-8b"])
    let ollama = LocalServerSuggestionModel(server: .ollama, model: "yerel:1b", isAvailable: true, port: server.port)
    #expect(try await ollama.respond(instructions: "talimat", prompt: "soru") == "2, 1")
    let chat = try #require(server.requests.last { $0.path == "/api/chat" }?.json)
    #expect(chat["model"] as? String == "yerel:1b" && chat["stream"] as? Bool == false)
    let messages = try #require(chat["messages"] as? [[String: String]])
    #expect(messages == [["role": "system", "content": "talimat"], ["role": "user", "content": "soru"]])

    let lmStudio = LocalServerSuggestionModel(server: .lmStudio, model: "qwen3-8b", isAvailable: true, port: server.port)
    let placement = await Suggestions.placeFile("su ekim.pdf", content: nil, candidates: ["Elektrik", "Sigorta"], model: lmStudio)
    #expect(placement == .value(Suggestions.FilePlacement(order: [], newFolder: "Faturalar/Su")))
    #expect(server.requests.last?.path == "/v1/chat/completions")

    await #expect(throws: (any Error).self) { _ = try await LocalModelServer.request("/yonlendir", port: server.port, body: nil, timeout: 3) }
    await #expect(throws: (any Error).self) { _ = try await LocalModelServer.request("/yok", port: server.port, body: nil, timeout: 3) }
    #expect(!server.requests.contains { $0.path == "/disari" })
    #expect(await LocalModelServer.ollama.models(port: 1) == nil)
    await #expect(throws: (any Error).self) { _ = try await LocalServerSuggestionModel(server: .ollama, model: "yerel:1b", isAvailable: false).respond(instructions: "", prompt: "") }
}

/// Yol önerileri: modelin "NEW:" yolu hedefin içinde kalır, aday klasörle aynıysa o aday seçilir; alt klasör şablonu
/// en az bir tarih belirteci içermeli ve hedefin dışına çıkamaz; örnek klasörler en yeni değişenden sıralanır.
@Test func pathSuggestionsAreValidated() throws {
    let candidates = ["Faturalar/Elektrik (123456789)", "Sigorta"]
    #expect(Suggestions.parsePlacement("2, 1", candidates: candidates) == .init(order: ["Sigorta", "Faturalar/Elektrik (123456789)"], newFolder: nil))
    #expect(Suggestions.parsePlacement("NEW: \"../../Faturalar/./Su\"", candidates: candidates) == .init(order: [], newFolder: "Faturalar/Su"))
    #expect(Suggestions.parsePlacement("- new: sigorta", candidates: candidates) == .init(order: ["Sigorta"], newFolder: nil))
    #expect(Suggestions.parsePlacement("1\nNEW: Belgeler/Kira", candidates: candidates) == .init(order: ["Faturalar/Elektrik (123456789)"], newFolder: "Belgeler/Kira"))
    #expect(Suggestions.parsePlacement("NEW: {year}/x", candidates: candidates) == nil)
    #expect(Suggestions.parsePlacement("NEW: ..", candidates: candidates) == nil)
    #expect(Suggestions.parsePlacement("bilmiyorum", candidates: candidates) == nil)
    #expect(Suggestions.parsePlacement("NEW: a/b/c/d/e/f/g", candidates: candidates) == nil)

    #expect(Suggestions.cleanFolderTemplate("Template: `{year}/{month}-{monthName}`") == "{year}/{month}-{monthName}")
    #expect(Suggestions.cleanFolderTemplate("/Faturalar//{year}/ ") == "Faturalar/{year}")
    #expect(Suggestions.cleanFolderTemplate("Faturalar/Elektrik") == nil)
    #expect(Suggestions.cleanFolderTemplate("../{year}") == nil)
    #expect(Suggestions.cleanFolderTemplate("{yil}/{month}") == nil)
    #expect(Suggestions.cleanFolderTemplate("") == nil)

    let w = try Workspace()
    try w.write("Hedef/2025/01-Ocak/a.pdf", "a")
    try w.write("Hedef/2026/10-Ekim/b.pdf", "b")
    try w.write("Hedef/.gizli/c.pdf", "c")
    try w.write("Hedef/kok.pdf", "d")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: w.url("Hedef/2025/01-Ocak/a.pdf").path)
    #expect(Suggestions.exampleFolders(in: w.url("Hedef")) == ["2026/10-Ekim", "2025/01-Ocak"])
}

/// Sahte modelle yol önerileri: alt klasör şablonu ve dosyanın yeri; model kullanılamıyorsa öneri yok.
@Test func pathSuggestionsWithAModel() async {
    struct Model: SuggestionModel {
        var isAvailable = true
        var answer: String
        func respond(instructions: String, prompt: String) async throws -> String { answer }
    }
    #expect(await Suggestions.folderTemplate(examples: ["2026/10-Ekim"], model: Model(answer: "{year}/{month}-{monthName}")) == .value("{year}/{month}-{monthName}"))
    #expect(await Suggestions.folderTemplate(examples: ["Faturalar/Su"], model: Model(answer: "{year}/{month}")) == .noSuggestion)
    #expect(await Suggestions.folderTemplate(examples: [], model: Model(answer: "{year}")) == .noSuggestion)
    #expect(await Suggestions.folderTemplate(examples: ["x"], model: Model(isAvailable: false, answer: "{year}")) == .unavailable)
    #expect(await Suggestions.placeFile("a.pdf", content: "içerik", candidates: [], model: Model(answer: "NEW: Belgeler")) == .value(.init(order: [], newFolder: "Belgeler")))
    #expect(await Suggestions.placeFile("a.pdf", content: nil, candidates: ["A", "B"], model: Model(isAvailable: false, answer: "1")) == .unavailable)
}

/// Otomatik kip: kullanılamayan model sorulmaz; hata veren ve geçersiz yanıt veren modelden sonra sıradaki sorulur, geçerli
/// yanıtı veren kaydedilir; hiçbiri yanıt veremezse öneri yoktur ve hata atılmaz. Kayıtlı sıra onarılır.
@Test func automaticModeFallsBackSilently() async throws {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }
    struct Member: SuggestionModel {
        var name: String
        var isAvailable = true
        var answer: String?
        var calls: Calls
        func respond(instructions: String, prompt: String) async throws -> String {
            calls.add(name)
            guard let answer else { throw LocalModelServer.Failure.unavailable }
            return answer
        }
    }
    let calls = Calls()
    let chain = FallbackSuggestionModel([
        (name: "Kapalı", model: Member(name: "Kapalı", isAvailable: false, answer: "1", calls: calls)),
        (name: "Hatalı", model: Member(name: "Hatalı", answer: nil, calls: calls)),
        (name: "Geçersiz", model: Member(name: "Geçersiz", answer: "bilmiyorum", calls: calls)),
        (name: "İyi", model: Member(name: "İyi", answer: "2", calls: calls)),
        (name: "Sonraki", model: Member(name: "Sonraki", answer: "1", calls: calls)),
    ])
    #expect(chain.isAvailable && chain.lastSource == nil)
    let pair = ["X", "Y"].map { FolderSuggester.Suggestion(path: $0, score: 0) }
    #expect(await Suggestions.rankFolders(pair, for: "a.pdf", content: nil, model: chain).value?.map(\.path) == ["Y", "X"])
    #expect(calls.all == ["Hatalı", "Geçersiz", "İyi"] && chain.lastSource == "İyi")

    let dead = FallbackSuggestionModel([
        (name: "A", model: Member(name: "A", answer: nil, calls: calls)),
        (name: "B", model: Member(name: "B", isAvailable: false, answer: "1", calls: calls)),
    ])
    #expect(await Suggestions.placeFile("a.pdf", content: nil, candidates: ["X", "Y"], model: dead) == .unavailable)
    #expect(await Suggestions.folderTemplate(examples: ["Faturalar/Su"], model: dead) == .unavailable && dead.lastSource == nil)
    await #expect(throws: (any Error).self) { _ = try await dead.respond(instructions: "", prompt: "") }
    #expect(!FallbackSuggestionModel([]).isAvailable)

    // Gerçek HTTP: Ollama'nın portu kapalı (erişilemiyor), sıradaki LM Studio yanıt verir.
    let server = try FakeModelServer { request in
        request.path == "/v1/chat/completions" ? FakeModelServer.json(["choices": [["message": ["content": "2"]]]]) : FakeModelServer.json([:], status: 404)
    }
    defer { server.stop() }
    let local = FallbackSuggestionModel([
        (name: "Ollama", model: LocalServerSuggestionModel(server: .ollama, model: "yerel:1b", isAvailable: true, port: 1)),
        (name: "LM Studio", model: LocalServerSuggestionModel(server: .lmStudio, model: "qwen3-8b", isAvailable: true, port: server.port)),
    ])
    #expect(await Suggestions.placeFile("su.pdf", content: nil, candidates: ["Elektrik", "Su"], model: local) == .value(.init(order: ["Su"], newFolder: nil)))
    #expect(local.lastSource == "LM Studio")

    #expect(SuggestionProvider.order(["lmStudio", "bilinmeyen", "automatic", "lmStudio"]) == [.lmStudio, .apple, .ollama])
    #expect(SuggestionProvider.order([]) == SuggestionProvider.models)
}

/// İsteğe bağlı: bu Mac'teki gerçek Ollama ile (COPIATOR_OLLAMA_TESTS=1). Bulut modelleri listede yoktur; yerel bir
/// modelle yol önerisi geçerli bir yanıt verir.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COPIATOR_OLLAMA_TESTS"] == "1", "COPIATOR_OLLAMA_TESTS verilmedi"))
func liveOllamaGivesValidPathSuggestions() async throws {
    let models = try #require(await LocalModelServer.ollama.models(), "Ollama çalışmıyor")
    #expect(models.allSatisfy { !LocalModelServer.isCloud($0) })
    let name = try #require(models.first, "Ollama'da yerel model yok")
    let model = LocalServerSuggestionModel(server: .ollama, model: name, isAvailable: true)
    let placement = await Suggestions.placeFile("Enerjisa elektrik faturası Ekim 2026.pdf", content: "ENERJİSA elektrik faturası",
                                                candidates: ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta"], model: model).value
    print("Ollama \(name) yer önerisi: \(String(describing: placement))")
    if let placement {
        #expect(placement.order.allSatisfy { ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta"].contains($0) })
        #expect(placement.newFolder.map { !$0.contains("..") && !$0.hasPrefix("/") } ?? true)
    }
    let template = await Suggestions.folderTemplate(examples: ["2025/01-Ocak", "2025/02-Şubat", "2026/10-Ekim"], model: model).value
    print("Ollama \(name) alt klasör şablonu: \(String(describing: template))")
    if let template {
        #expect(RoutePlacement(folderTemplate: template).problems().isEmpty)
    }
}

/// İsteğe bağlı: bu Mac'teki gerçek LM Studio (Bionic) sunucusuyla (COPIATOR_LMSTUDIO_TESTS=1). Gömme modelleri listede
/// yoktur; bir sohbet modeli varsa yol önerisi geçerli bir yanıt verir.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COPIATOR_LMSTUDIO_TESTS"] == "1", "COPIATOR_LMSTUDIO_TESTS verilmedi"))
func liveLMStudioGivesValidPathSuggestions() async throws {
    let models = try #require(await LocalModelServer.lmStudio.models(), "LM Studio (Bionic) sunucusu çalışmıyor")
    print("LM Studio sohbet modelleri: \(models)")
    #expect(models.allSatisfy { !$0.lowercased().contains("embed") })
    guard let name = models.first else { return }
    let model = LocalServerSuggestionModel(server: .lmStudio, model: name, isAvailable: true)
    let placement = await Suggestions.placeFile("Enerjisa elektrik faturası Ekim 2026.pdf", content: "ENERJİSA elektrik faturası",
                                                candidates: ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta"], model: model).value
    print("LM Studio \(name) yer önerisi: \(String(describing: placement))")
    if let placement {
        #expect(placement.order.allSatisfy { ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta"].contains($0) })
        #expect(placement.newFolder.map { !$0.contains("..") && !$0.hasPrefix("/") } ?? true)
    }
}
