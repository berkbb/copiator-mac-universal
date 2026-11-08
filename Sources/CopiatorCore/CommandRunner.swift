// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bir alt sürecin tamamlanmış çıktısı.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Motor (rsync) ve yardımcı betikler çalıştırılırken oluşabilecek, motordan bağımsız hatalar.
/// rsync'in kendi çıkış kodları ayrıca `RsyncOutcome` ile sınıflandırılır.
public enum EngineError: Error, Equatable, Sendable {
    case engineNotFound
    case timedOut
    case cancelled
    case failed(code: Int32, message: String)
    /// Kum havuzu istendi ama sandbox-exec bu Mac'te yok: program korumasız başlatılmadı.
    case sandboxUnavailable

    /// Çıktıdaki hata/uyarı satırlarını kısa bir özete indirger.
    public static func diagnostic(from output: String, limit: Int = 6) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("\u{8}") }
        let markers = ["rsync:", "rsync error", "ERROR", "WARNING", "error", "warning", "failed", "Cannot", "cannot"]
        let interesting = lines.filter { line in markers.contains { line.contains($0) } }
        let chosen = interesting.isEmpty ? Array(lines.suffix(3)) : Array(interesting.prefix(limit))
        return chosen.joined(separator: "\n")
    }
}

/// Alt süreçleri çalıştırır; satır satır çıktı, zaman aşımı ve iptal desteği sunar.
public struct CommandRunner: Sendable {
    public let executableURL: URL
    /// Doluysa program sandbox-exec altında bu kurallarla çalıştırılır.
    public let sandbox: SandboxProfile?
    /// Program arka plan hizmet sınıfıyla (`.background`) başlatılır: macOS disk G/Ç'sini ve işlemci önceliğini düşürür,
    /// öteki uygulamalar önce gelir. sandbox-exec'ten rsync'e ve rsync'in alt süreçlerine geçer.
    public let lowPriority: Bool

    public init(executableURL: URL, sandbox: SandboxProfile? = nil, lowPriority: Bool = false) {
        self.executableURL = executableURL
        self.sandbox = sandbox
        self.lowPriority = lowPriority
    }

    /// Bir alt sürecin stdout ve stderr'de biriktirilebilecek en çok baytı. Kuru çalıştırmada (`-n -i`) milyonlarca
    /// dosyalık bir ağacın farkları gigabaytlarca çıktı üretebilir; sınır aşılırsa süreç durdurulur ve işlem hatayla biter.
    public static let maxOutputBytes = 512 << 20

    /// Süreç bittikten sonra çıktının sonunun okunması için beklenen en uzun süre.
    public static let drainGracePeriod: TimeInterval = 2

    /// `retainStdout` kapalıyken saklanan son çıktı (yalnızca tanı için).
    public static let streamTailBytes = 64 << 10

    /// Zaman aşımı ve sonlandırma sonrası zorla durdurma bu seri kuyrukta çalışır. Ortak GCD havuzu
    /// (`DispatchQueue.global()`, eşzamanlı özel kuyruklar da) bloklanan işlerle dolduğunda oradaki bir zamanlayıcı
    /// saniyelerce gecikebilir (0,3 sn'lik zaman aşımı 8,8 sn sonra çalıştı); seri özel kuyruk gerektiğinde kendi iş
    /// parçacığını alır. Buradaki işler kısadır, bloklamaz.
    static let timers = DispatchQueue(label: "com.babadogantech.copiator.runner.timers")

    /// Süreci çalıştırır. Sıfırdan farklı çıkış kodu hata sayılmaz; sınıflandırma çağırana aittir.
    /// - Parameters:
    ///   - timeout: Saniye; aşılırsa süreç sonlandırılır ve `timedOut` fırlatılır.
    ///   - workingDirectory: Göreli yollar için çalışma klasörü.
    ///   - input: stdin'e yazılacak veri. Yoksa stdin boştur; süreç girdi beklerse takılmaz.
    ///   - retainStdout: false ise stdout biriktirilmez (yalnızca son `streamTailBytes` saklanır). rsync
    ///     `--info=progress2` her saniye onlarca satır yazar; saatler süren bir kopyada bunlar belleği doldururdu.
    ///   - onRecord: stdout'taki her kayıt (`\r` ya da `\n` ile biten satır) için çağrılır; rsync ilerleme satırlarını
    ///     `\r` ile, dosya ve fark satırlarını `\n` ile bitirir.
    public func run(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int = CommandRunner.maxOutputBytes,
        workingDirectory: URL? = nil,
        input: Data? = nil,
        retainStdout: Bool = true,
        onRecord: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let launch: (URL, [String])
        if let sandbox {
            // Kum havuzu istenip başlatıcı yoksa çalıştırma reddedilir (korumasız çalıştırmaya düşülmez).
            guard SandboxProfile.isAvailable else { throw EngineError.sandboxUnavailable }
            launch = (SandboxProfile.launcher, sandbox.launchArguments(executable: executableURL, arguments: arguments))
        } else {
            launch = (executableURL, arguments)
        }
        let box = try ProcessBox(executableURL: launch.0, arguments: launch.1, input: input)
        if let workingDirectory { box.process.currentDirectoryURL = workingDirectory }
        if lowPriority { box.process.qualityOfService = .background }
        let state = RunState(onRecord: onRecord, maxOutputBytes: maxOutputBytes, retainStdout: retainStdout)
        // Çıktı sınırı aşılırsa süreci durdur; drain EOF alır, bekleyen devam hata ile döner.
        state.onLimitExceeded = { box.terminate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let readers = DispatchGroup()
                readers.enter()
                readers.enter()

                box.process.terminationHandler = { finished in
                    let exitCode = finished.terminationStatus
                    ChildProcessGuard.unregister(finished.processIdentifier)
                    // Tüm çıktı okunduktan sonra sonucu teslim et. Süreç bittiği hâlde boruyu açık tutan bir torun süreç
                    // (ör. öldürülen bir kabuğun "sleep" çocuğu) EOF'u geciktirirse en çok `drainGracePeriod` beklenir;
                    // yoksa iptal, torun çıkana kadar asılı kalırdı.
                    // Bekleme bloklar: ortak havuzu doldurmasın diye kendi iş parçacığında (okuyucular gibi).
                    CommandRunner.startReader {
                        _ = readers.wait(timeout: .now() + CommandRunner.drainGracePeriod)
                        continuation.resume(with: state.finish(exitCode: exitCode))
                    }
                }

                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: EngineError.engineNotFound)
                    return
                }
                // Uygulama çökerse ya da zorla kapatılırsa süreç yetim kalmasın (bkz. `ChildProcessGuard`). Süreç kayıttan
                // önce bittiyse sonlanma işleyicisinin silmesi kaçmış olabilir: kayıt hemen geri alınır.
                let pid = box.process.processIdentifier
                ChildProcessGuard.register(pid, name: executableURL.lastPathComponent)
                if !box.process.isRunning { ChildProcessGuard.unregister(pid) }

                // Borular kendi iş parçacıklarında okunur: çok sayıda eşzamanlı süreçte GCD havuzu dolsa da okuma hemen
                // başlar. Havuzdan bir iş parçacığı beklenseydi süreç bittikten sonraki `drainGracePeriod` okuma hiç
                // başlamadan dolabilir ve çıktı kaybolurdu.
                Self.startReader {
                    box.drain(box.stdoutPipe) { state.appendStdout($0) }
                    readers.leave()
                }
                Self.startReader {
                    box.drain(box.stderrPipe) { state.appendStderr($0) }
                    readers.leave()
                }

                if state.isCancelled { box.terminate() }
                if let timeout {
                    CommandRunner.timers.asyncAfter(deadline: .now() + timeout) {
                        if box.isRunning {
                            state.markTimedOut()
                            box.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            box.terminate()
        }
    }
}

extension CommandRunner {
    /// Boruyu sonuna kadar okuyan ayrı bir iş parçacığı (okuma bloklanır; GCD havuzundan iş parçacığı tutmaz).
    fileprivate static func startReader(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "CommandRunner.reader"
        thread.start()
    }
}

extension CommandRunner {
    /// Çocuk sürecin ortamı: UTF-8 bir karakter yerel ayarı olmayan ortama `LC_CTYPE=UTF-8` eklenir.
    ///
    /// Finder'dan ya da Kestirmeler'den açılan bir uygulamanın ortamında `LANG` yoktur; süreç C yerel ayarında başlar.
    /// rsync 3.5.2 adlardaki ve hata iletilerindeki "uç birim denetim karakterlerini" etkin yerel ayara göre kaçışlar
    /// (NEWS 3.5.2): C yerel ayarında UTF-8'in 0x80–0x9F baytları (ğ, ş, Ğ, Ş'nin ikinci baytı) denetim karakteri sayılır
    /// ve hata ayrıntısında "Foto\#237raflar" yazar; `-8` yalnızca dosya listesini korur, stderr iletilerini korumaz
    /// (ölçüldü, 3.5.2). Yerel ayar UTF-8 iken 3.5.1 ile aynı ham baytlar yazılır. `LC_ALL` her şeyi ezdiği için UTF-8
    /// olmayan bir `LC_ALL` kaldırılır; UTF-8 bir ayar varsa ortam değiştirilmez.
    nonisolated static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        func isUTF8(_ value: String?) -> Bool {
            guard let value else { return false }
            let lower = value.lowercased()
            return lower.contains("utf-8") || lower.contains("utf8")
        }
        let effective = environment["LC_ALL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["LC_CTYPE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["LANG"].flatMap { $0.isEmpty ? nil : $0 }
        guard !isUTF8(effective) else { return environment }
        var result = environment
        if let all = result["LC_ALL"], !isUTF8(all) { result["LC_ALL"] = nil }
        result["LC_CTYPE"] = "UTF-8"
        return result
    }
}

/// Process ve borularını eşzamanlı kapanışlara güvenle taşımak için kutu.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    init(executableURL: URL, arguments: [String], input: Data?) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = CommandRunner.childEnvironment(ProcessInfo.processInfo.environment)
        if let input {
            // Veri süreç başlamadan boruya yazılıp yazma ucu kapatılır: çocuk süreç veriyi ve ardından EOF okur.
            // Böylece kapanmış boruya yazma (SIGPIPE) olamaz. Veri küçüktür, boru tamponuna sığar.
            let stdinPipe = Pipe()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM'i yok sayan (ör. takılmış bir disk G/Ç'sinde bekleyen) süreç bu süre sonunda SIGKILL ile durdurulur.
    static let killGracePeriod: TimeInterval = 2

    /// rsync SIGTERM alınca yarım dosyayı (`--partial`) saklar, kendi çocuklarını durdurur ve 20 koduyla çıkar.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        CommandRunner.timers.asyncAfter(deadline: .now() + Self.killGracePeriod) { [self] in
            // Süreç hâlâ çalışıyorsa zorla durdur; böylece sonlanma işleyicisi çalışır ve bekleyen devam (continuation) döner.
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func drain(_ pipe: Pipe, _ consume: (Data) -> Void) {
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            consume(data)
        }
    }
}

/// Çıktıyı biriktiren ve kayıtları bildiren, kilitle korunan durum.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    /// Henüz `\r` ya da `\n` ile bitmemiş kayıt parçası (parçalar arasında bölünmüş satır).
    private var pending = Data()
    private var totalBytes = 0
    private var cancelled = false
    private var timedOut = false
    private var overflowed = false
    /// Sonuç teslim edildi; sonradan gelen (torun süreçten kalan) çıktı yok sayılır.
    private var finished = false
    private let maxOutputBytes: Int
    private let retainStdout: Bool
    /// Çıktı sınırı aşıldığında bir kez çağrılır (süreci durdurmak için). Drain başlamadan ayarlanır.
    var onLimitExceeded: (@Sendable () -> Void)?
    private let onRecord: (@Sendable (String) -> Void)?

    /// Tek bir kaydın en çok uzunluğu: satır sonu hiç gelmeyen hostil bir çıktı bekleyen tamponu büyütmesin.
    static let maxRecordBytes = 64 << 10

    init(onRecord: (@Sendable (String) -> Void)?, maxOutputBytes: Int, retainStdout: Bool) {
        self.onRecord = onRecord
        self.maxOutputBytes = maxOutputBytes
        self.retainStdout = retainStdout
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func markCancelled() { lock.withLock { cancelled = true } }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func appendStdout(_ data: Data) {
        var records: [String] = []
        var fireLimit = false
        lock.withLock {
            if overflowed || finished { return }
            if retainStdout {
                if totalBytes + data.count > maxOutputBytes {
                    overflowed = true
                    fireLimit = true
                    return
                }
                totalBytes += data.count
                stdout.append(data)
            } else {
                // Yalnızca son kısım saklanır (tanı için); ilerleme satırları bellekte birikmez.
                stdout.append(data)
                if stdout.count > CommandRunner.streamTailBytes { stdout = stdout.suffix(CommandRunner.streamTailBytes) }
            }
            guard onRecord != nil else { return }
            pending.append(data)
            var start = pending.startIndex
            for index in pending.indices where pending[index] == 0x0A || pending[index] == 0x0D {
                if index > start { records.append(String(decoding: pending[start..<index], as: UTF8.self)) }
                start = pending.index(after: index)
            }
            pending = pending[start...]
            if pending.count > Self.maxRecordBytes { pending = Data(pending.suffix(Self.maxRecordBytes)) }
        }
        if fireLimit { onLimitExceeded?() }
        for record in records { onRecord?(record) }
    }

    func appendStderr(_ data: Data) {
        var fireLimit = false
        lock.withLock {
            if overflowed || finished { return }
            if totalBytes + data.count > maxOutputBytes {
                overflowed = true
                fireLimit = true
                return
            }
            totalBytes += data.count
            stderr.append(data)
        }
        if fireLimit { onLimitExceeded?() }
    }

    func finish(exitCode: Int32) -> Result<ProcessResult, Error> {
        var tail: String?
        let result: Result<ProcessResult, Error> = lock.withLock {
            finished = true
            if !pending.isEmpty, onRecord != nil {
                tail = String(decoding: pending, as: UTF8.self)
                pending = Data()
            }
            if cancelled { return .failure(EngineError.cancelled) }
            if timedOut { return .failure(EngineError.timedOut) }
            if overflowed {
                return .failure(EngineError.failed(code: exitCode, message: "Output exceeded the size limit and was stopped."))
            }
            return .success(ProcessResult(
                exitCode: exitCode,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            ))
        }
        if let tail { onRecord?(tail) }
        return result
    }
}
