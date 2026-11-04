// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

extension Int64 {
    /// Taşma yerine sınırda duran toplama: bozuk ya da uydurma boyutlar (ör. `Int64.max`) çökmeye yol açmasın.
    public func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}

extension Sequence where Element == Int64 {
    public func saturatingSum() -> Int64 { reduce(0) { $0.saturatingAdding($1) } }
}

/// Kopyalamadan önce ve kopyalama sürerken boş alan denetimi.
public enum DiskSpace {
    /// Sistemin işlemesi için bırakılan pay.
    public static let reserve: Int64 = 1 << 30

    public static func availableCapacity(at url: URL, fileManager: FileManager = .default) -> Int64? {
        let anchor = existingAncestor(of: url, fileManager: fileManager)
        let values = try? anchor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Birimin toplam boyutu (bilinmiyorsa nil).
    public static func totalCapacity(at url: URL, fileManager: FileManager = .default) -> Int64? {
        let anchor = existingAncestor(of: url, fileManager: fileManager)
        return (try? anchor.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// Hedef birim için bırakılacak pay: en çok `reserve` (1 GB), ama birimin %2'sinden fazla değil. Sistem birimleri
    /// her zaman tam payı alır (51 GB'tan büyükler); 1 GB'lık bir USB bellek ise yalnızca payı yüzünden kullanılamaz
    /// hâle gelmez.
    public static func reserve(forVolumeCapacity capacity: Int64?) -> Int64 {
        guard let capacity, capacity > 0 else { return reserve }
        return min(reserve, capacity / 50)
    }

    /// Boyutu bilinmeyen birim (nil) engellenmez; kopyalama rsync'in kendi hatasıyla durur.
    public static func hasRoom(required: Int64, available: Int64?, reserve: Int64 = reserve) -> Bool {
        guard let available else { return true }
        return required <= max(0, available - reserve)
    }

    /// Dosya ve klasörlerin (alt öğeleri dahil) diskteki toplam mantıksal boyutu. Sembolik bağlantılar izlenmez.
    /// - Parameter isCancelled: Büyük ağaçlarda tarama iptal edilebilsin diye her klasörde sorulur.
    public static func totalSize(of urls: [URL], isCancelled: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: total = total.saturatingAdding(Int64(info.st_size))
            case S_IFDIR: total = total.saturatingAdding(regularFileBytes(below: url.path, isCancelled: isCancelled))
            default: break
            }
        }
        return total
    }

    /// Klasör ağacındaki sıradan dosyaların boyutu ("._" ile başlayanlar dahil; bağlantılar izlenmez).
    static func regularFileBytes(below path: String, isCancelled: () -> Bool) -> Int64 {
        guard !isCancelled() else { return 0 }
        var total: Int64 = 0
        for name in (try? entries(ofDirectory: path)) ?? [] {
            let child = (path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: total = total.saturatingAdding(Int64(info.st_size))
            case S_IFDIR: total = total.saturatingAdding(regularFileBytes(below: child, isCancelled: isCancelled))
            default: break
            }
        }
        return total
    }

    /// Klasördeki tüm adlar. `FileManager.contentsOfDirectory` "._" ile başlayan sıradan dosyaları gizler; burada
    /// `readdir` ile hepsi okunur ("." ve ".." hariç).
    public static func entries(ofDirectory path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw CocoaError(.fileReadNoPermission) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Kopyalama için gereken en az alan: kaynakların boyutu, hedefte zaten bulunan kopyanın boyutu kadar azalır
    /// (yarıda kalmış bir işin sürdürülmesi ya da güncelleme yalnızca eksik kısmı yazar).
    public static func requiredForCopy(sourceBytes: Int64, existingDestinationBytes: Int64) -> Int64 {
        max(0, sourceBytes - max(0, existingDestinationBytes))
    }

    static func existingAncestor(of url: URL, fileManager: FileManager) -> URL {
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}

/// Yetersiz disk alanı.
public struct InsufficientSpaceError: Error, Equatable, Sendable {
    public let required: Int64
    public let available: Int64
    /// Ön denetimde değil, yazma sürerken (kaynak büyüdü ya da başka bir uygulama diski doldurdu) disk dolmak
    /// üzereyken durduruldu.
    public let stoppedWhileWriting: Bool

    public init(required: Int64, available: Int64, stoppedWhileWriting: Bool = false) {
        self.required = required
        self.available = available
        self.stoppedWhileWriting = stoppedWhileWriting
    }

    /// Gerekirse hata fırlatır.
    public static func check(required: Int64, at url: URL) throws {
        let available = DiskSpace.availableCapacity(at: url)
        let reserve = DiskSpace.reserve(forVolumeCapacity: DiskSpace.totalCapacity(at: url))
        guard DiskSpace.hasRoom(required: required, available: available, reserve: reserve) else {
            throw InsufficientSpaceError(required: required, available: available ?? 0)
        }
    }
}

/// Kopyalama sürerken hedef birimdeki boş alanı izler.
///
/// Ön denetim kaynak boyutuna dayanır; kopyalama sırasında kaynak büyüyebilir ya da başka bir uygulama hedef birimi
/// doldurabilir. Boş alan `floor` altına inince iş iptal edilir (rsync durdurulur) ve `InsufficientSpaceError`
/// fırlatılır; `--partial` sayesinde iş daha sonra kaldığı yerden sürdürülebilir.
public enum DiskSpaceGuard {
    public static let interval: Duration = .milliseconds(500)
    /// Sistemin çalışması için bırakılan en az boş alan (ön denetimdeki payın yarısı, 512 MB).
    public static let floor: Int64 = DiskSpace.reserve / 2

    /// Birime göre taban: en çok 512 MB, küçük birimlerde (USB bellek) ön denetim payının yarısı.
    public static func floor(forVolumeCapacity capacity: Int64?) -> Int64 {
        DiskSpace.reserve(forVolumeCapacity: capacity) / 2
    }

    /// `operation` sürerken boş alanı izler; alan tükenirse onu iptal edip hata fırlatır, yoksa sonucunu döndürür.
    public static func run<T: Sendable>(
        watching url: URL,
        floor: Int64 = floor,
        interval: Duration = interval,
        available: (@Sendable () -> Int64?)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let available = available ?? { DiskSpace.availableCapacity(at: url) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                while true {
                    // İş iptal edilince (ör. Duraklat) izleyici sessizce çıkar: kendi CancellationError'ı işin "iptal
                    // edildi" sonucundan önce gelip bir hata gibi gösterilmesin.
                    do { try await Task.sleep(for: interval) } catch { return nil }
                    if let free = available(), free < floor {
                        throw InsufficientSpaceError(required: floor, available: max(0, free), stoppedWhileWriting: true)
                    }
                }
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
            }
            throw CancellationError()
        }
    }
}

/// Hedef birimin dosya sistemi. exFAT/FAT izin, sahip ve ACL saklayamaz; FAT ayrıca zamanları 2 saniyelik
/// çözünürlükle tutar.
public enum FileSystemKind: String, Sendable, Codable, Equatable {
    case apfs, hfs, exfat, fat, ntfs, network, other

    /// POSIX izinleri, sahip/grup ve ACL tutulamayan birimler.
    public var lacksPosixMetadata: Bool { self == .exfat || self == .fat || self == .ntfs }

    /// Değişiklik zamanını 2 saniyelik adımlarla tutan birim: rsync `--modify-window=1` ile karşılaştırmalı, yoksa her
    /// çalıştırmada tüm dosyaları değişmiş sayıp yeniden kopyalar.
    public var hasCoarseTimestamps: Bool { self == .fat }

    /// `statfs.f_fstypename` değerinden ("apfs", "exfat", "msdos", "smbfs"…).
    public init(typeName: String) {
        switch typeName.lowercased() {
        case "apfs": self = .apfs
        case "hfs": self = .hfs
        case "exfat": self = .exfat
        case "msdos", "fat", "fat32", "vfat": self = .fat
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs": self = .ntfs
        case "smbfs", "nfs", "afpfs", "webdav", "cifs": self = .network
        default: self = .other
        }
    }

    /// Yolun (ya da var olan en yakın üst klasörünün) bulunduğu birimin dosya sistemi.
    public static func of(_ url: URL, fileManager: FileManager = .default) -> FileSystemKind {
        let anchor = DiskSpace.existingAncestor(of: url, fileManager: fileManager)
        var info = statfs()
        guard statfs(anchor.path, &info) == 0 else { return .other }
        let name = withUnsafePointer(to: info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return FileSystemKind(typeName: name)
    }
}

/// Sahibin izin bitleri eksik olan öğelerde (0555 klasör, 0444/0111/0000 dosya) geçici izin.
///
/// macOS sahibinin yazma izni olmayan öğelere karantina işareti yazmayı (setxattr) reddeder; öğeler sahibine aittir,
/// izin kısa süre açılıp geri alınır. Sembolik bağlantılara dokunulmaz (chmod bağlantının gösterdiğini değiştirirdi).
enum OwnerAccess {
    /// Eksikse `bits` izinlerini ekler. - Returns: Değiştirildiyse eski kip; değişmediyse nil.
    static func add(_ bits: mode_t, on path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK, info.st_mode & bits != bits else { return nil }
        let original = info.st_mode & 0o7777
        return chmod(path, original | bits) == 0 ? original : nil
    }

    /// `body` süresince sahibine `bits` izinlerini verir, sonra eski kipi geri yükler.
    static func granting<T>(_ bits: mode_t, on path: String, _ body: () throws -> T) rethrows -> T {
        guard let original = add(bits, on: path) else { return try body() }
        defer { chmod(path, original) }
        return try body()
    }
}
