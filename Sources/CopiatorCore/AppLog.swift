// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os
import Synchronization

/// Uygulama günlüğü (konsol): uygulama, rsync motoru, işler, diskler, bütünlük denetimleri ve güncellemeler.
///
/// Her kayıt üç yere gider:
/// - macOS birleşik günlüğü: Konsol uygulamasında `com.babadogantech.copiator` alt sistemiyle canlı izlenir. Özet açık
///   (`public`), ayrıntı gizlidir (`<private>`): ayrıntıda dosya adları ve rsync iletileri olabilir.
/// - Kullanıcıya özel günlük dosyası (`~/Library/Logs/Copiator/Copiator.log`, 0600): uygulama yeniden açıldıktan sonra
///   önceki oturumun kayıtları da okunur. Konsol'un "Günlük Raporları" bölümünde de görünür.
/// - Uygulama içindeki Günlük penceresi (son `capacity` kayıt).
///
/// Özet metne dosya adı ya da yol konmaz; işler kimliklerinin ilk sekiz karakteriyle anılır.
public final class AppLog: Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case info, warning, error

        /// "Hatalar ve Sorunlar" süzgecine giren düzeyler.
        public var isProblem: Bool { self != .info }

        /// Konsol'daki düzey. Rutin kayıtlar (açılış, iş başlangıçları ve bitişleri) `.info`: Konsol onları ancak
        /// "Bilgi İletilerini Dahil Et" açıkken gösterir, macOS da kalıcı olarak saklamaz. Hatalar ve uyarılar `.error`.
        /// Uygulamanın Günlük penceresi ve dosyası düzeyden bağımsız olarak her kaydı tutar.
        var osLogType: OSLogType { self == .info ? .info : .error }
    }

    public enum Category: String, Sendable, CaseIterable {
        case app, engine, job, disk, integrity, update
    }

    public struct Entry: Identifiable, Sendable, Equatable {
        /// Kayıt sırası; dosyadan okunan önceki kayıtlar da sırayla numaralanır.
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: Category
        /// Kaydı yazan sürecin kimliği: önceki oturumun kayıtları yeni oturumunkilerden ayrılır.
        public let process: Int32
        /// Konsol'da açık görünen özet (dosya adı, yol, parola içermez).
        public let message: String
        /// Ayrıntı (ör. rsync'in hata iletisi): Konsol'da gizli, uygulama içinde ve dosyada açık.
        public let detail: String?

        public init(id: Int, date: Date, level: Level, category: Category, process: Int32, message: String, detail: String?) {
            self.id = id
            self.date = date
            self.level = level
            self.category = category
            self.process = process
            self.message = message
            self.detail = detail
        }

        /// Özet ve (varsa) ayrıntı, ayrı satırlarda.
        public var text: String { detail.map { message + "\n" + $0 } ?? message }
    }

    public static let subsystem = "com.babadogantech.copiator"
    public static let fileName = "Copiator.log"
    public static let previousFileName = "Copiator.1.log"

    /// `~/Library/Logs/Copiator`
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Copiator", isDirectory: true)
    }

    /// Uygulamanın günlüğü. Testler (`swift test`) kullanıcının günlük dosyasına ve Konsol'a yazmaz; yalnızca bellekte tutar.
    public static let shared: AppLog = {
        let isApp = Bundle.main.bundleIdentifier == subsystem
        return AppLog(directory: isApp ? defaultDirectory : nil, mirrorsToSystemLog: isApp)
    }()

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    private struct State {
        var entries: [Entry] = []
        var nextID = 0
        var descriptor: Int32 = -1
        var fileBytes = 0
        var observers: [UUID: @Sendable () -> Void] = [:]
    }

    /// Günlük dosyasının klasörü; nil ise kayıtlar yalnızca bellekte tutulur.
    public let directory: URL?
    public let mirrorsToSystemLog: Bool
    /// Bellekte (ve pencerede) tutulan en çok kayıt.
    public let capacity: Int
    /// Dosya bu boyutu aşınca `Copiator.1.log` adıyla bir kez saklanır, yenisine başlanır.
    public let maxFileBytes: Int
    private let state = Mutex(State())

    public init(directory: URL?, mirrorsToSystemLog: Bool = false, capacity: Int = 2000, maxFileBytes: Int = 1 << 20) {
        self.directory = directory
        self.mirrorsToSystemLog = mirrorsToSystemLog
        self.capacity = max(1, capacity)
        self.maxFileBytes = max(1024, maxFileBytes)
        guard let directory else { return }
        // Önceki oturumların kayıtları: önce saklanan eski dosya, sonra güncel dosya.
        let previous = [Self.previousFileName, Self.fileName].flatMap { name in
            Self.parse(String(decoding: (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data(), as: UTF8.self))
        }
        state.withLock { state in
            for entry in previous.suffix(self.capacity) {
                state.entries.append(Entry(
                    id: state.nextID, date: entry.date, level: entry.level, category: entry.category,
                    process: entry.process, message: entry.message, detail: entry.detail
                ))
                state.nextID += 1
            }
        }
    }

    deinit {
        state.withLock { state in
            if state.descriptor >= 0 { close(state.descriptor) }
        }
    }

    public var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    /// Kayıtlar, eskiden yeniye.
    public var entries: [Entry] { state.withLock { $0.entries } }

    public func info(_ category: Category, _ message: String, detail: String? = nil) {
        log(.info, category, message, detail: detail)
    }

    public func warning(_ category: Category, _ message: String, detail: String? = nil) {
        log(.warning, category, message, detail: detail)
    }

    public func error(_ category: Category, _ message: String, detail: String? = nil) {
        log(.error, category, message, detail: detail)
    }

    public func log(_ level: Level, _ category: Category, _ message: String, detail: String? = nil, date: Date = Date()) {
        let detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        if mirrorsToSystemLog, let logger = Self.loggers[category] {
            if let detail {
                logger.log(level: level.osLogType, "\(message, privacy: .public) — \(detail, privacy: .private)")
            } else {
                logger.log(level: level.osLogType, "\(message, privacy: .public)")
            }
        }
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            let entry = Entry(id: state.nextID, date: date, level: level, category: category, process: getpid(), message: message, detail: detail)
            state.nextID += 1
            state.entries.append(entry)
            if state.entries.count > capacity { state.entries.removeFirst(state.entries.count - capacity) }
            write(Self.line(for: entry), into: &state)
            return Array(state.observers.values)
        }
        for observer in observers { observer() }
    }

    /// Kayıtları ve günlük dosyalarını siler.
    public func clear() {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.entries.removeAll()
            if state.descriptor >= 0 {
                close(state.descriptor)
                state.descriptor = -1
            }
            state.fileBytes = 0
            if let directory {
                for name in [Self.fileName, Self.previousFileName] {
                    unlink(directory.appendingPathComponent(name).path)
                }
            }
            return Array(state.observers.values)
        }
        for observer in observers { observer() }
    }

    /// Her yeni kayıtta (ve silmede) çağrılır; çağrı herhangi bir iş parçacığından gelebilir.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.observers[id] = handler }
        return id
    }

    public func removeObserver(_ id: UUID) {
        state.withLock { _ = $0.observers.removeValue(forKey: id) }
    }

    // MARK: - Dosya

    /// Satırı dosyaya ekler; dosya sınırı aşacaksa önce eskisini saklar. Yazılamazsa (ör. disk dolu) kayıt bellekte kalır.
    private func write(_ line: String, into state: inout State) {
        guard let directory else { return }
        let data = Array(line.utf8)
        if state.descriptor >= 0, state.fileBytes > 0, state.fileBytes + data.count > maxFileBytes {
            close(state.descriptor)
            state.descriptor = -1
            rename(directory.appendingPathComponent(Self.fileName).path, directory.appendingPathComponent(Self.previousFileName).path)
        }
        if state.descriptor < 0 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.appendingPathComponent(Self.fileName).path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return }
            // Daha geniş izinle kalmış bir dosya (ör. elle oluşturulmuş) yalnızca kullanıcıya açık olsun.
            fchmod(descriptor, 0o600)
            var info = stat()
            state.fileBytes = fstat(descriptor, &info) == 0 ? Int(info.st_size) : 0
            state.descriptor = descriptor
        }
        let written = data.withUnsafeBytes { Foundation.write(state.descriptor, $0.baseAddress, $0.count) }
        if written > 0 { state.fileBytes += written }
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    /// Dosya satırı: tarih, düzey, kategori, süreç, özet, ayrıntı (sekmeyle ayrılmış; sekme, satır sonu ve ters bölü kaçışlı).
    static func line(for entry: Entry) -> String {
        [
            entry.date.formatted(dateStyle), entry.level.rawValue, entry.category.rawValue, String(entry.process),
            escape(entry.message), escape(entry.detail ?? ""),
        ].joined(separator: "\t") + "\n"
    }

    /// Dosya içeriğini kayıtlara çevirir; tanınmayan satırlar atlanır. Kimlikler sonradan verilir.
    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let date = try? dateStyle.parse(String(fields[0])),
                  let level = Level(rawValue: String(fields[1])),
                  let category = Category(rawValue: String(fields[2])),
                  let process = Int32(fields[3]) else { return nil }
            let detail = unescape(fields[5])
            return Entry(
                id: 0, date: date, level: level, category: category, process: process,
                message: unescape(fields[4]), detail: detail.isEmpty ? nil : detail
            )
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\t": result += "\\t"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\r\n": result += "\\r\\n"
            default: result.append(character)
            }
        }
        return result
    }

    static func unescape<S: StringProtocol>(_ text: S) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

extension AppLog {
    /// Milisaniye cinsinden geçen süre (günlük iletileri için).
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Hatanın Konsol'da açık gösterilebilecek türü (dosya adı, yol içermez) ve gizli tutulacak ayrıntısı.
    public static func describe(_ error: any Error) -> (kind: String, detail: String?) {
        switch error {
        case let error as EngineError:
            switch error {
            case .failed(let code, let message): ("rsync failed with exit code \(code)", message)
            case .engineNotFound: ("rsync could not be started", nil)
            case .timedOut: ("rsync timed out", nil)
            case .cancelled: ("cancelled", nil)
            case .sandboxUnavailable: ("rsync was not started because its sandbox (sandbox-exec) cannot be run", nil)
            }
        case let error as InsufficientSpaceError:
            ("not enough disk space (required \(error.required) bytes, available \(error.available) bytes)", nil)
        case is CancellationError:
            ("cancelled", nil)
        default:
            ("\((error as NSError).domain) error \((error as NSError).code)", (error as NSError).localizedDescription)
        }
    }

    /// İş kimliğinin kısa biçimi (günlükte işler adıyla değil bununla anılır).
    public static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// İptal mi? (İptal bir hata değildir; günlüğe bilgi olarak yazılır.)
    public static func isCancellation(_ error: any Error) -> Bool {
        if case .cancelled? = error as? EngineError { return true }
        return error is CancellationError
    }
}
