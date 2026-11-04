// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Uygulama çökse ya da zorla kapatılsa da rsync yetim kalıp hedefe yazmayı sürdürmesin.
///
/// - Çalışan alt süreçler sinyal güvenli bir tabloda tutulur. Çökme sinyallerinde (SIGSEGV, SIGABRT, SIGTRAP…) ve
///   SIGTERM, SIGHUP, SIGINT, SIGQUIT'te işleyici önce onlara SIGTERM gönderir (rsync yarım dosyayı saklayıp çıkar),
///   sonra sinyali varsayılan davranışıyla yeniden yükseltir: uygulama yine sonlanır, çökme raporu bozulmaz.
/// - SIGKILL yakalanamaz: süreçler ayrıca bir dosyaya da yazılır. Uygulama yeniden açılınca, sahibi ölmüş (üst süreci
///   launchd olmuş) ve başlangıç zamanı kayıtla mikrosaniyesine kadar aynı olan süreçler durdurulur. Başlangıç zamanı
///   denetimi, aynı numarayı sonradan almış ilgisiz bir süreci durdurmayı önler.
public enum ChildProcessGuard {
    /// Kayıt dosyasındaki bir süreç.
    public struct Record: Codable, Equatable, Sendable {
        public var pid: Int32
        public var startSeconds: UInt64
        public var startMicroseconds: UInt64
        public var name: String

        public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, name: String) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
            self.name = name
        }
    }

    static let capacity = 64

    /// Sinyal işleyicisinin okuduğu tablo. İşleyici kilit almaz; hizalı 32 bit okumalar yapar (sinyal güvenli).
    nonisolated(unsafe) static let slots: UnsafeMutablePointer<pid_t> = {
        let pointer = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
        return pointer
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [Record] = []
    nonisolated(unsafe) private static var stateFile: URL?

    /// Kayıt dosyası (uygulama: ~/Library/Application Support/Copiator/running-processes.json). Testlerde verilmez;
    /// kayıtlar yalnızca bellekte tutulur.
    public static func configure(stateFile url: URL?) {
        lock.withLock {
            stateFile = url
            persistLocked()
        }
    }

    /// Şu an kayıtlı alt süreçler.
    public static var registeredPIDs: [pid_t] {
        lock.withLock { (0..<capacity).map { slots[$0] }.filter { $0 > 0 } }
    }

    /// Başlatılan bir alt süreci kaydeder (`CommandRunner` her süreç için çağırır).
    static func register(_ pid: pid_t, name: String) {
        guard pid > 0 else { return }
        let info = bsdInfo(pid)
        lock.withLock {
            if let free = (0..<capacity).first(where: { slots[$0] == 0 }) { slots[free] = pid }
            if let info {
                records.append(Record(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, name: name))
            }
            persistLocked()
        }
    }

    /// Biten bir alt sürecin kaydını siler.
    static func unregister(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.withLock {
            for index in 0..<capacity where slots[index] == pid { slots[index] = 0 }
            records.removeAll { $0.pid == pid }
            persistLocked()
        }
    }

    private static func persistLocked() {
        guard let stateFile else { return }
        if records.isEmpty {
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    // MARK: Çökme işleyicileri

    /// Sonlandıran sinyaller. SIGKILL ve SIGSTOP yakalanamaz (açılıştaki temizlik onları karşılar).
    public static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP, SIGTERM, SIGHUP, SIGINT, SIGQUIT]

    /// Çökme ve sonlandırma sinyallerine işleyici kurar (yalnızca uygulamada; testlerde kurulmaz).
    public static func installCrashHandlers() {
        _ = slots // Tablo işleyiciden önce hazırlanır: işleyicide tembel ilklendirme olmasın.
        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: childProcessGuardSignalHandler)
            sigemptyset(&action.sa_mask)
            // İşleyici bir kez çalışır, sonra varsayılana döner: yeniden yükseltilen sinyal uygulamayı sonlandırır.
            action.sa_flags = Int32(SA_RESETHAND)
            sigaction(signal, &action, nil)
        }
    }

    /// Kayıtlı tüm alt süreçlere SIGTERM gönderir (sinyal güvenli: yalnızca `kill`).
    static func terminateRegisteredFromSignalHandler() {
        for index in 0..<capacity {
            let pid = slots[index]
            if pid > 0 { kill(pid, SIGTERM) }
        }
    }

    // MARK: Açılışta temizlik

    /// Önceki oturumdan kalan yetim süreçleri durdurur ve kayıt dosyasını siler.
    /// - Returns: Durdurulan süreçler.
    @discardableResult
    public static func reapOrphans(stateFile url: URL, gracePeriod: TimeInterval = 2) -> [Record] {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        let orphans = saved.filter(isOrphan)
        for record in orphans { kill(record.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, orphans.contains(where: isAlive) { usleep(50_000) }
        for record in orphans where isAlive(record) { kill(record.pid, SIGKILL) }
        return orphans
    }

    /// Kayıttaki süreç hâlâ aynı süreç (başlangıç zamanı birebir aynı) ve sahipsiz (üst süreci launchd).
    static func isOrphan(_ record: Record) -> Bool {
        guard let info = bsdInfo(record.pid), matches(info, record) else { return false }
        return info.pbi_ppid == 1
    }

    /// Kayıttaki süreç hâlâ çalışıyor (zombi değil).
    static func isAlive(_ record: Record) -> Bool {
        guard let info = bsdInfo(record.pid), matches(info, record) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    private static func matches(_ info: proc_bsdinfo, _ record: Record) -> Bool {
        info.pbi_start_tvsec == record.startSeconds && info.pbi_start_tvusec == record.startMicroseconds
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Bir sürecin kaydı (testler için).
    static func record(for pid: pid_t, name: String) -> Record? {
        bsdInfo(pid).map { Record(pid: pid, startSeconds: $0.pbi_start_tvsec, startMicroseconds: $0.pbi_start_tvusec, name: name) }
    }
}

/// C işlev göstergesi olarak kurulan işleyici: yakalama yapmaz, yalnızca sinyal güvenli çağrılar.
private func childProcessGuardSignalHandler(_ signal: Int32) {
    ChildProcessGuard.terminateRegisteredFromSignalHandler()
    raise(signal)
}
