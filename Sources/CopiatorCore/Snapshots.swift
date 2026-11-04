// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Otomatik anlık görüntü yedekleri (Time Machine benzeri). Açıkken iş hedefi bir "anlık görüntü kökü"dür: her
/// çalıştırma kökte tarihli yeni bir klasöre ("2026-10-21-143005") yazar, değişmeyen dosyalar bir önceki anlık görüntüyle
/// sabit bağlantıyla paylaşılır (`--link-dest`, yer kaplamaz). Yarım kalan çalıştırma "….partial" klasöründe bekler ve
/// sonraki çalıştırmada sürdürülür; ancak başarıyla bitince tarihli ada taşınır ve "Latest" bağlantısı ona çevrilir.
public struct SnapshotOptions: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Saklama kuralları (Time Machine ve rsnapshot'taki gibi): bir anlık görüntü herhangi bir kural onu tutuyorsa kalır.
    /// Hepsi boşsa hiçbir anlık görüntü silinmez. En yeni anlık görüntü her koşulda kalır.
    /// Son N anlık görüntü.
    public var keepLast: Int?
    /// Anlık görüntüsü olan son N günün her birinin en yenisi.
    public var keepDaily: Int?
    /// Anlık görüntüsü olan son N haftanın her birinin en yenisi.
    public var keepWeekly: Int?
    /// Anlık görüntüsü olan son N ayın her birinin en yenisi.
    public var keepMonthly: Int?

    public init(enabled: Bool = false, keepLast: Int? = nil, keepDaily: Int? = nil, keepWeekly: Int? = nil, keepMonthly: Int? = nil) {
        self.enabled = enabled
        self.keepLast = keepLast
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
    }

    /// En az bir saklama kuralı var: eski anlık görüntüler silinebilir (iş eklenirken ayrıca onay istenir).
    public var hasRetention: Bool { enabled && [keepLast, keepDaily, keepWeekly, keepMonthly].contains { $0 != nil } }

    /// Saklama sayıları en az 1 olmalı (0 "hepsini sil" anlamına gelirdi).
    public var isValid: Bool { [keepLast, keepDaily, keepWeekly, keepMonthly].allSatisfy { ($0 ?? 1) >= 1 } }

    private enum CodingKeys: String, CodingKey { case enabled, keepLast, keepDaily, keepWeekly, keepMonthly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        keepLast = (try? c.decodeIfPresent(Int.self, forKey: .keepLast)) ?? nil
        keepDaily = (try? c.decodeIfPresent(Int.self, forKey: .keepDaily)) ?? nil
        keepWeekly = (try? c.decodeIfPresent(Int.self, forKey: .keepWeekly)) ?? nil
        keepMonthly = (try? c.decodeIfPresent(Int.self, forKey: .keepMonthly)) ?? nil
    }
}

/// Anlık görüntü kökündeki klasörlerin adları, hazırlanması, tamamlanması ve budanması. Yalnızca adı tam olarak
/// "yyyy-MM-dd-HHmmss" biçiminde olan gerçek klasörler anlık görüntü sayılır; kökteki başka hiçbir şeye dokunulmaz.
public enum SnapshotStore {
    /// En yeni anlık görüntüyü gösteren bağlantının adı.
    public static let latestLinkName = "Latest"
    /// Süren ya da yarım kalan anlık görüntünün sonu.
    public static let partialSuffix = ".partial"

    /// Bir çalıştırmanın hazırlığı: rsync'in yazacağı klasör ve bağlantı verilecek önceki anlık görüntü.
    public struct Preparation: Equatable, Sendable {
        /// rsync'in hedefi ("….partial").
        public var partial: URL
        /// En yeni tamamlanmış anlık görüntü (`--link-dest`); ilk anlık görüntüde nil.
        public var previous: URL?
        /// Yarım kalmış bir anlık görüntü sürdürülüyor.
        public var resumed: Bool
    }

    // MARK: Adlar

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return formatter
    }

    /// Anlık görüntünün adı (yerel saat): "2026-10-21-143005". Adlar alfabetik sırada da zaman sırasındadır.
    public static func name(for date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone).string(from: date)
    }

    /// Adın gösterdiği zaman; ad tam biçimde değilse nil.
    public static func date(fromName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.utf8.count == 17, name.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil,
              let date = formatter(timeZone).date(from: name), Self.name(for: date, timeZone: timeZone) == name else { return nil }
        return date
    }

    public static func isSnapshotName(_ name: String, timeZone: TimeZone = .current) -> Bool {
        date(fromName: name, timeZone: timeZone) != nil
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func names(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// Tamamlanmış anlık görüntülerin adları, eskiden yeniye.
    public static func completeSnapshots(in root: URL, timeZone: TimeZone = .current) -> [String] {
        names(in: root)
            .filter { isSnapshotName($0, timeZone: timeZone) && isRealDirectory(root.appendingPathComponent($0)) }
            .sorted()
    }

    /// Yarım kalmış anlık görüntülerin adları ("….partial"), eskiden yeniye.
    public static func partialSnapshots(in root: URL, timeZone: TimeZone = .current) -> [String] {
        names(in: root)
            .filter { name in
                name.hasSuffix(partialSuffix) && isSnapshotName(String(name.dropLast(partialSuffix.count)), timeZone: timeZone)
                    && isRealDirectory(root.appendingPathComponent(name))
            }
            .sorted()
    }

    /// En yeni tamamlanmış anlık görüntü.
    public static func latest(in root: URL, timeZone: TimeZone = .current) -> URL? {
        completeSnapshots(in: root, timeZone: timeZone).last.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: Çalıştırma

    /// Klasör oluşturmadan, bir çalıştırmanın kullanacağı yolları hesaplar (komut önizlemesi için).
    public static func plan(in root: URL, now: Date = Date(), timeZone: TimeZone = .current) -> Preparation {
        let previous = latest(in: root, timeZone: timeZone)
        if let partial = partialSnapshots(in: root, timeZone: timeZone).last {
            return Preparation(partial: root.appendingPathComponent(partial, isDirectory: true), previous: previous, resumed: true)
        }
        let partial = root.appendingPathComponent(name(for: now, timeZone: timeZone) + partialSuffix, isDirectory: true)
        return Preparation(partial: partial, previous: previous, resumed: false)
    }

    /// Bir çalıştırmayı hazırlar: yarım kalan anlık görüntü varsa (en yenisi) o sürdürülür, yoksa yeni bir "….partial"
    /// klasörü oluşturulur. Klasörü uygulama oluşturur; rsync yalnızca içine yazar.
    public static func prepare(in root: URL, now: Date = Date(), timeZone: TimeZone = .current) throws -> Preparation {
        var preparation = plan(in: root, now: now, timeZone: timeZone)
        if !preparation.resumed {
            var date = now
            while FileManager.default.fileExists(atPath: preparation.partial.path) {
                date = date.addingTimeInterval(1)
                preparation.partial = root.appendingPathComponent(name(for: date, timeZone: timeZone) + partialSuffix, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: preparation.partial, withIntermediateDirectories: false)
        }
        return preparation
    }

    /// Önceki yedeğe göre değişmesi gereken iş: hedef "….partial" klasörü, `--link-dest` önceki anlık görüntü.
    /// Kullanıcının seçtiği "önceki yedek" ayarı anlık görüntü kipinde kullanılmaz.
    public static func apply(_ preparation: Preparation, to job: TransferJob) -> TransferJob {
        var job = job
        job.destination = preparation.partial
        if let previous = preparation.previous {
            job.options.advanced.referenceMode = .linkDest
            job.options.advanced.referenceDirectory = previous.path
        } else {
            job.options.advanced.referenceMode = .none
            job.options.advanced.referenceDirectory = nil
        }
        return job
    }

    /// Yarım anlık görüntüyü tarihli adına taşır ve "Latest" bağlantısını ona çevirir.
    /// - Returns: Tamamlanan anlık görüntünün klasörü.
    public static func finalize(partial: URL, in root: URL, now: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        // Yeni anlık görüntünün adı her zaman en yenisinden sonra gelir (aynı saniyede biten iki çalıştırmada ya da saat
        // geri alındığında da): "en yeni" ada göre bulunur.
        var date = now
        if let newest = completeSnapshots(in: root, timeZone: timeZone).last.flatMap({ Self.date(fromName: $0, timeZone: timeZone) }),
           newest >= date {
            date = newest.addingTimeInterval(1)
        }
        var final = root.appendingPathComponent(name(for: date, timeZone: timeZone), isDirectory: true)
        while FileManager.default.fileExists(atPath: final.path) {
            date = date.addingTimeInterval(1)
            final = root.appendingPathComponent(name(for: date, timeZone: timeZone), isDirectory: true)
        }
        try FileManager.default.moveItem(at: partial, to: final)
        updateLatestLink(in: root, to: final.lastPathComponent)
        return final
    }

    /// "Latest" → en yeni anlık görüntü (göreli bağlantı). Aynı adda gerçek bir dosya ya da klasör varsa dokunulmaz.
    /// Bağlantı geçici bir adla oluşturulup yerine taşınır: hiçbir an bozuk ya da eksik kalmaz.
    @discardableResult
    public static func updateLatestLink(in root: URL, to name: String) -> Bool {
        let link = root.appendingPathComponent(latestLinkName)
        var info = stat()
        if lstat(link.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK { return false }
        let temporary = root.appendingPathComponent(".\(latestLinkName)-\(UUID().uuidString)")
        guard symlink(name, temporary.path) == 0 else { return false }
        guard rename(temporary.path, link.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    // MARK: Saklama

    /// Saklama kurallarına göre kalacak anlık görüntüler (saf; testlerde sabit takvimle denetlenir).
    /// Adı ayrıştırılamayanlar hiç değerlendirilmez, dolayısıyla silinmez.
    public static func retained(_ names: [String], options: SnapshotOptions, calendar: Calendar) -> Set<String> {
        let timeZone = calendar.timeZone
        let dated = names.compactMap { name in date(fromName: name, timeZone: timeZone).map { (name: name, date: $0) } }
            .sorted { $0.date > $1.date }
        guard options.hasRetention else { return Set(dated.map(\.name)) }
        var keep = Set<String>()
        if let newest = dated.first { keep.insert(newest.name) }
        if let count = options.keepLast { dated.prefix(max(0, count)).forEach { keep.insert($0.name) } }
        /// Her dönemin (gün, hafta, ay) en yenisi; anlık görüntüsü olan son `count` dönem.
        func keepNewest(per period: (Date) -> [Int], count: Int?) {
            guard let count, count > 0 else { return }
            var periods = Set<[Int]>()
            for item in dated {
                let key = period(item.date)
                if periods.contains(key) { continue }
                if periods.count == count { break }
                periods.insert(key)
                keep.insert(item.name)
            }
        }
        keepNewest(per: { let c = calendar.dateComponents([.year, .month, .day], from: $0); return [c.year ?? 0, c.month ?? 0, c.day ?? 0] },
                   count: options.keepDaily)
        keepNewest(per: { let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0); return [c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0] },
                   count: options.keepWeekly)
        keepNewest(per: { let c = calendar.dateComponents([.year, .month], from: $0); return [c.year ?? 0, c.month ?? 0] },
                   count: options.keepMonthly)
        return keep
    }

    /// Budamanın sonucu.
    public struct PruneResult: Equatable, Sendable {
        public var removed: [String] = []
        public var failed: [String] = []
    }

    /// Saklama kurallarının tutmadığı tamamlanmış anlık görüntüleri siler. `protecting` (az önce tamamlanan) hiçbir
    /// koşulda silinmez; kural yoksa hiçbir şey silinmez. Yarım anlık görüntülere ve kökteki başka öğelere dokunulmaz.
    public static func prune(
        in root: URL, options: SnapshotOptions, protecting: String, calendar: Calendar = .current,
        isCancelled: () -> Bool = { false }
    ) -> PruneResult {
        var result = PruneResult()
        guard options.hasRetention else { return result }
        let names = completeSnapshots(in: root, timeZone: calendar.timeZone)
        let keep = retained(names, options: options, calendar: calendar).union([protecting])
        for name in names where !keep.contains(name) {
            if isCancelled() { break }
            let url = root.appendingPathComponent(name, isDirectory: true)
            if removeTree(at: url) { result.removed.append(name) } else { result.failed.append(name) }
        }
        return result
    }

    /// Bir anlık görüntü klasörünü siler. İzinler korunmuş anlık görüntülerde salt okunur klasörler olabilir: önce
    /// sahibine yazma izni verilir (yalnızca silinecek ağacın içinde). Sembolik bağlantılar izlenmez.
    static func removeTree(at url: URL) -> Bool {
        let fileManager = FileManager.default
        /// Klasöre sahibi için okuma, yazma ve girme izni verir (gerekiyorsa). Klasör, içi okunmadan önce açılır.
        func makeWritable(_ path: String) {
            var info = stat()
            let needed = S_IRUSR | S_IWUSR | S_IXUSR
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & needed != needed else { return }
            chmod(path, (info.st_mode & 0o7777) | needed)
        }
        makeWritable(url.path)
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let item as URL in enumerator { makeWritable(item.path) }
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
