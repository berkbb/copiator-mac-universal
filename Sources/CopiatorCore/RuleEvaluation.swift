// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import AVFoundation
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Öğe

/// Fotoğraf ya da video üst verisi.
public struct MediaInfo: Equatable, Sendable {
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Saniye.
    public var duration: Double?
    public var cameraModel: String?

    public init(captureDate: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: Double? = nil, cameraModel: String? = nil) {
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.cameraModel = cameraModel
    }

    /// Uzun kenar (piksel).
    public var longestSide: Int? {
        switch (pixelWidth, pixelHeight) {
        case let (width?, height?): max(width, height)
        case let (width?, nil): width
        case let (nil, height?): height
        default: nil
        }
    }

    /// Resimlerde ImageIO (piksel boyutu, EXIF çekim tarihi, kamera modeli), video ve seste AVFoundation (süre, görüntü
    /// boyutu, oluşturulma tarihi, QuickTime kamera modeli). Okunamayan alan boş kalır.
    public static func load(_ url: URL, type: UTType?) async -> MediaInfo? {
        guard let type else { return nil }
        if type.conforms(to: .image) { return image(url) }
        if type.conforms(to: .audiovisualContent) { return await audiovisual(url) }
        return nil
    }

    static func image(_ url: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var info = MediaInfo()
        info.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        info.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.captureDate = exifDate(text)
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        return info
    }

    /// EXIF tarihi "yyyy:MM:dd HH:mm:ss" (yerel saat).
    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Piksel sayısı: bozuk bir dosyanın sonsuz, NaN ya da çok büyük boyutu `Int`e çevrilirken çökertmesin.
    static func pixels(_ value: CGFloat) -> Int? {
        let rounded = abs(value).rounded()
        guard rounded.isFinite, rounded < CGFloat(Int32.max) else { return nil }
        return Int(rounded)
    }

    static func audiovisual(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            info.pixelWidth = pixels(rect.width)
            info.pixelHeight = pixels(rect.height)
        }
        if let creation = try? await asset.load(.creationDate), let date = try? await creation.load(.dateValue) {
            info.captureDate = date
        }
        if let metadata = try? await asset.load(.metadata) {
            let model = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataModel).first
            if let model, let text = try? await model.load(.stringValue) { info.cameraModel = text }
        }
        return info
    }
}

/// Kurala sorulan öğe. Ad ve yol karşılaştırma için Unicode NFC biçimindedir (macOS adları ayrık biçimde de saklayabilir).
/// Boyut, tarih, etiket ve gizlilik yalnızca bir koşul sorduğunda okunur ve saklanır; fotoğraf/video bilgisini tarayıcı
/// önceden yükler. Testler üst veriyi doğrudan verebilir.
public final class RuleItem: @unchecked Sendable {
    public let name: String
    public let fileExtension: String
    public let folders: [String]
    /// NFC biçiminde göreli yol (karşılaştırma için).
    public let relativePath: String
    public let isDirectory: Bool
    public let type: UTType?
    let url: URL?
    private let attributes: [FileAttributeKey: Any]?

    /// Diskten okunmadan verilen üst veri (testler).
    public struct Metadata: Sendable {
        public var size: Int64?
        public var modified: Date?
        public var created: Date?
        public var added: Date?
        public var tags: [String]?
        public var hiddenFlag: Bool?
        public var media: MediaInfo?
        /// Dosyanın metni (PDF ya da düz metin; bkz. `ContentReader`).
        public var text: String?

        public init(size: Int64? = nil, modified: Date? = nil, created: Date? = nil, added: Date? = nil, tags: [String]? = nil,
                    hiddenFlag: Bool? = nil, media: MediaInfo? = nil, text: String? = nil) {
            self.size = size
            self.modified = modified
            self.created = created
            self.added = added
            self.tags = tags
            self.hiddenFlag = hiddenFlag
            self.media = media
            self.text = text
        }
    }

    private var metadata: Metadata
    private var loaded: Set<String> = []

    /// - Parameters:
    ///   - relativePath: Kaynağa göre göreli yol ("2026/Raporlar/satis.xlsx").
    ///   - url: Diskteki öğe (üst veri buradan okunur); yoksa yalnızca ad, yol ve tür değerlendirilir.
    ///   - attributes: Dizin taramasının verdiği öznitelikler (boyut ve tarihler ek sistem çağrısı olmadan).
    public init(relativePath: String, isDirectory: Bool = false, url: URL? = nil, attributes: [FileAttributeKey: Any]? = nil,
                metadata: Metadata = Metadata()) {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        name = components.last ?? normalized
        folders = Array(components.dropLast())
        self.relativePath = normalized
        self.isDirectory = isDirectory
        let ext = (name as NSString).pathExtension
        fileExtension = ext
        if isDirectory {
            type = ext.isEmpty ? .folder : UTType(filenameExtension: ext, conformingTo: .package) ?? UTType(filenameExtension: ext)
        } else {
            type = ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
        }
        self.url = url
        self.attributes = attributes
        self.metadata = metadata
    }

    /// Bir alanı bir kez yükler (verilmişse olduğu gibi kalır).
    private func value<T>(_ key: String, _ keyPath: WritableKeyPath<Metadata, T?>, load: () -> T?) -> T? {
        if let value = metadata[keyPath: keyPath] { return value }
        guard !loaded.contains(key) else { return nil }
        loaded.insert(key)
        metadata[keyPath: keyPath] = load()
        return metadata[keyPath: keyPath]
    }

    /// Bayt; paket klasörlerinde içindekilerin toplamı.
    public var size: Int64? {
        value("size", \.size) {
            guard let url else { return nil }
            if isDirectory { return DiskSpace.totalSize(of: [url]) }
            if let size = attributes?[.size] as? NSNumber { return size.int64Value }
            var info = stat()
            return lstat(url.path, &info) == 0 ? Int64(info.st_size) : nil
        }
    }

    public var modified: Date? {
        value("modified", \.modified) {
            attributes?[.modificationDate] as? Date ?? (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    public var created: Date? {
        value("created", \.created) {
            attributes?[.creationDate] as? Date ?? (try? url?.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
    }

    /// Finder'daki "Eklenme Tarihi" (klasöre konduğu an).
    public var added: Date? {
        value("added", \.added) { (try? url?.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate }
    }

    public var tags: [String] {
        value("tags", \.tags) { (try? url?.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? [] } ?? []
    }

    /// Adı nokta ile başlayan (ya da böyle bir klasörün içindeki) ya da Finder'da gizli işaretli öğe.
    public var isHidden: Bool {
        if name.hasPrefix(".") || folders.contains(where: { $0.hasPrefix(".") }) { return true }
        return value("hidden", \.hiddenFlag) {
            guard let url else { return false }
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0
        } ?? false
    }

    /// Dosyanın metni: yalnızca PDF ve düz metin dosyalarında, ilk sorulduğunda okunur.
    public var textContent: String? {
        value("text", \.text) {
            guard !isDirectory, let url, ContentReader.canRead(type) else { return nil }
            return ContentReader.text(of: url, type: type)
        }
    }

    public var media: MediaInfo? {
        get { metadata.media }
        set { metadata.media = newValue }
    }
}

// MARK: - Değerlendirme

/// Derlenmiş kurallar: düzenli ifadeler bir kez derlenir; göreli tarihler `now` anına göre hesaplanır.
public struct RuleEvaluator: @unchecked Sendable {
    /// Bir düzenli ifade eşleşmesinin adım sınırı. ICU uzun bir eşleşmede ilerleme bloğunu her başlangıç konumunda ve
    /// geri izleme adımlarına göre düzenli aralıklarla çağırır: sayı saatten bağımsızdır, her seferinde aynıdır. Olağan bir
    /// ifade bir yolda en çok yolun uzunluğu kadar çağırır; "(a+)+$" gibi geri izlemesi katlanarak büyüyen bir ifade sınırı
    /// aşar, eşleşme durdurulur ve tarama hatayla biter. Sınır olmasaydı tarama hiç bitmez, iptal de edilemezdi.
    public static let regexStepBudget = 5_000

    /// Adım sınırını aşan düzenli ifade.
    public struct RunawayRegex: Error, Equatable, Sendable {
        public var pattern: String
    }

    /// "Son N gün içinde" ölçütünde en çok bu kadar birim: takvim hesabı (ve `Int` çevirisi) taşmasın.
    static let maxCalendarAmount = 1_000_000.0

    public let rules: RuleGroup
    private let regexes: [UUID: NSRegularExpression]
    private let runaway = RunawayRecord()
    private let now: Date
    private let calendar: Calendar
    /// İçerik koşullarına uyan öğelerin (NFC) göreli yolları (Spotlight'tan).
    private let contentMatches: [UUID: Set<String>]
    /// "Hedefte kopyası var" ölçütü için hedefin içerik dizini (hedef verilmediyse hiçbir dosya "var" sayılmaz).
    private let destinationIndex: DestinationIndex?

    public init(_ rules: RuleGroup, now: Date = Date(), calendar: Calendar = .current, contentMatches: [UUID: Set<String>] = [:],
                destinationIndex: DestinationIndex? = nil) throws {
        self.rules = rules
        self.now = now
        self.calendar = calendar
        self.contentMatches = contentMatches
        self.destinationIndex = destinationIndex
        var regexes: [UUID: NSRegularExpression] = [:]
        for condition in rules.allConditions where condition.op == .matchesRegex && condition.op.input(for: condition.attribute) == .text {
            regexes[condition.id] = try NSRegularExpression(pattern: condition.value.precomposedStringWithCanonicalMapping)
        }
        self.regexes = regexes
    }

    public func matches(_ item: RuleItem) -> Bool { matches(item, rules, depth: 0) }

    /// Adım sınırını aşan ilk düzenli ifade (varsa o eşleşme "uymaz" sayıldı; tarama hatayla bitmeli).
    public var runawayPattern: String? { runaway.pattern }

    private func matches(_ item: RuleItem, _ group: RuleGroup, depth: Int) -> Bool {
        guard depth < RuleGroup.maxDepth else { return false }
        // Tembel sıra: ilk belirleyici sonuçta durulur (gerekmeyen üst veri okunmaz).
        let results = group.conditions.lazy.map { matches(item, $0) }
        let children = group.groups.lazy.filter { !$0.isEmpty }.map { matches(item, $0, depth: depth + 1) }
        switch group.match {
        case .all: return results.allSatisfy { $0 } && children.allSatisfy { $0 }
        case .any:
            if group.conditions.isEmpty && !group.groups.contains(where: { !$0.isEmpty }) { return true }
            return results.contains(true) || children.contains(true)
        case .none: return !results.contains(true) && !children.contains(true)
        }
    }

    private func matches(_ item: RuleItem, _ condition: RuleCondition) -> Bool {
        switch condition.attribute {
        case .name: return compare(item.name, condition)
        case .fileExtension: return compare(item.fileExtension, condition, stripDot: true)
        case .folderName: return item.folders.contains { compare($0, condition) }
        case .path: return compare(item.relativePath, condition)
        case .kind: return FileKind(rawValue: condition.value.trimmingCharacters(in: .whitespaces))?.matches(item.type) ?? false
        case .size: return compare(item.size.map(Double.init), condition)
        case .depth: return compare(Double(item.folders.count), condition)
        case .resolution: return compare(item.media?.longestSide.map(Double.init), condition)
        case .duration: return compare(item.media?.duration, condition)
        case .modified: return compare(item.modified, condition)
        case .created: return compare(item.created, condition)
        case .added: return compare(item.added, condition)
        case .captureDate: return compare(item.media?.captureDate, condition)
        case .cameraModel: return item.media?.cameraModel.map { compare($0, condition) } ?? false
        case .hidden: return condition.op == .isTrue ? item.isHidden : !item.isHidden
        case .inDestination:
            var present = false
            if let destinationIndex, !item.isDirectory, let url = item.url, let size = item.size {
                present = destinationIndex.contains(url, size: size)
            }
            return condition.op == .isTrue ? present : !present
        case .tag:
            switch condition.op {
            case .isTrue: return !item.tags.isEmpty
            case .isFalse: return item.tags.isEmpty
            default: return item.tags.contains { compare($0, condition) }
            }
        case .content:
            // Spotlight dizini bulduysa yeter; bulmadıysa (dizinlenmemiş birim, eski dizin) PDF ve metin dosyaları
            // doğrudan okunur.
            if contentMatches[condition.id]?.contains(item.relativePath) == true { return true }
            guard let text = item.textContent else { return false }
            return ContentReader.contains(text, condition.value)
        }
    }

    private func compare(_ text: String, _ condition: RuleCondition, stripDot: Bool = false) -> Bool {
        if condition.op == .matchesRegex {
            guard let regex = regexes[condition.id] else { return false }
            return firstMatch(regex, in: text)
        }
        let text = Self.fold(text)
        if condition.op == .isOneOf {
            return condition.listItems.contains { text.compare(Self.fold($0.precomposedStringWithCanonicalMapping), options: .caseInsensitive) == .orderedSame }
        }
        var value = Self.fold(condition.value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces))
        if stripDot { while value.hasPrefix(".") { value.removeFirst() } }
        guard !value.isEmpty else { return false }
        switch condition.op {
        case .contains: return text.range(of: value, options: .caseInsensitive) != nil
        case .equals: return text.compare(value, options: .caseInsensitive) == .orderedSame
        case .beginsWith: return text.range(of: value, options: [.caseInsensitive, .anchored]) != nil
        case .endsWith: return text.range(of: value, options: [.caseInsensitive, .anchored, .backwards]) != nil
        default: return false
        }
    }

    /// Adım sınırlı eşleşme (bkz. `regexStepBudget`).
    private func firstMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        var ticks = 0
        var matched = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
            if result != nil {
                matched = true
                stop.pointee = true
            } else {
                ticks += 1
                if ticks > Self.regexStepBudget { stop.pointee = true }
            }
        }
        if !matched, ticks > Self.regexStepBudget { runaway.record(regex.pattern) }
        return matched
    }

    /// Sayı: koşulun sayısı birimiyle çarpılır (MB → bayt, dakika → saniye); değer yoksa koşul tutmaz.
    private func compare(_ number: Double?, _ condition: RuleCondition) -> Bool {
        guard let number else { return false }
        let limit = condition.number * (condition.unit?.multiplier ?? 1)
        switch condition.op {
        case .greaterThan: return number > limit
        case .lessThan: return number < limit
        case .atMost: return number <= limit
        case .atLeast: return number >= limit
        case .equals: return number == limit
        default: return false
        }
    }

    /// Tarih: "son N … içinde" `now`dan geriye takvimle; "önce/sonra" seçilen günün başına ve sonuna göre.
    private func compare(_ date: Date?, _ condition: RuleCondition) -> Bool {
        guard let date else { return false }
        switch condition.op {
        case .withinLast, .notWithinLast:
            guard let (component, step) = condition.unit?.calendarComponent,
                  let cutoff = calendar.date(byAdding: component, value: -Int(min(condition.number.rounded(), Self.maxCalendarAmount)) * step,
                                             to: now) else { return false }
            return condition.op == .withinLast ? date >= cutoff : date < cutoff
        case .before:
            guard let day = condition.date else { return false }
            return date < calendar.startOfDay(for: day)
        case .after:
            guard let day = condition.date, let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return false }
            return date >= next
        default:
            return false
        }
    }

    /// Türkçe noktalı/noktasız i farkını kaldırır; büyük/küçük harf farkı karşılaştırmada ayrıca yok sayılır.
    static func fold(_ text: String) -> String {
        guard text.contains(where: { $0 == "ı" || $0 == "İ" }) else { return text }
        return text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
    }
}

/// Adım sınırını aşan düzenli ifadenin kaydı (değerlendiricinin kopyaları paylaşır).
private final class RunawayRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    var pattern: String? { lock.withLock { first } }
    func record(_ pattern: String) { lock.withLock { if first == nil { first = pattern } } }
}

// MARK: - Tarama

/// Kaynağı tarar ve kurallara uyan dosyaların göreli yollarını bulur. Klasörlerin kendisi listelenmez (rsync dosyaların
/// klasörlerini oluşturur); uygulama ve fotoğraf arşivi gibi paket klasörleri tek bir dosya gibi değerlendirilir.
public enum RuleScanner {
    public struct Result: Equatable, Sendable {
        /// Diskteki yazımıyla göreli yollar (rsync'e aynen verilir).
        public var paths: [String] = []
        /// Bakılan öğe sayısı.
        public var scanned = 0
    }

    /// - Parameters:
    ///   - skippedPaths: Hiç girilmeyecek göreli yollar (kum havuzunun okutmadığı kişisel klasörler).
    ///   - skippedNames: Hiçbir düzeyde girilmeyecek adlar (macOS sistem klasörleri).
    ///   - now: Göreli tarihlerin ("son 7 gün") başlangıcı.
    ///   - destination: "Hedefte kopyası var" ölçütü için hedef (yalnızca o ölçüt kullanılıyorsa taranır).
    ///   - onlyItems: Verilirse yalnızca kökteki bu öğeler (ve klasörse içleri) değerlendirilir (Finder'da seçilenler).
    public static func scan(
        _ root: URL, rules: RuleGroup, skippedPaths: Set<String> = [], skippedNames: Set<String> = [], now: Date = Date(),
        destination: URL? = nil, onlyItems: Set<String>? = nil, isCancelled: () -> Bool = { false }
    ) async throws -> Result {
        // İçerik koşulları taramadan önce Spotlight'a bir kez sorulur.
        var contentMatches: [UUID: Set<String>] = [:]
        for condition in rules.allConditions where condition.attribute == .content {
            contentMatches[condition.id] = Spotlight.relativePaths(containing: condition.value, in: root)
        }
        let index = try destination.flatMap { destination in
            try rules.allConditions.contains { $0.attribute == .inDestination } ? DestinationIndex(root: destination, isCancelled: isCancelled) : nil
        }
        let evaluator = try RuleEvaluator(rules, now: now, contentMatches: contentMatches, destinationIndex: index)
        let onlyItems = onlyItems.map { Set($0.map(\.precomposedStringWithCanonicalMapping)) }
        let needsMedia = rules.allConditions.contains { $0.attribute.needsMedia }
        var result = Result()
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        while let relative = enumerator.nextObject() as? String {
            if result.scanned % 256 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            result.scanned += 1
            let attributes = enumerator.fileAttributes
            let isDirectory = attributes?[.type] as? FileAttributeType == .typeDirectory
            let name = (relative as NSString).lastPathComponent
            if let onlyItems, let first = relative.split(separator: "/").first,
               !onlyItems.contains(String(first).precomposedStringWithCanonicalMapping) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if skippedPaths.contains(relative) || skippedNames.contains(name) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory {
                let ext = (name as NSString).pathExtension
                guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .package), type.conforms(to: .package) else {
                    continue
                }
                enumerator.skipDescendants()
            }
            let url = root.appendingPathComponent(relative)
            let item = RuleItem(relativePath: relative, isDirectory: isDirectory, url: url, attributes: attributes)
            if needsMedia, !isDirectory, let type = item.type, type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
                item.media = await MediaInfo.load(url, type: type)
            }
            if evaluator.matches(item) { result.paths.append(relative) }
            if let pattern = evaluator.runawayPattern { throw RuleEvaluator.RunawayRegex(pattern: pattern) }
        }
        return result
    }
}

/// Spotlight dizininden içerik araması (`kMDItemTextContent`). Dizini olmayan birimlerde (ör. Spotlight'ı kapalı harici
/// diskler, geçici klasörler) sonuç boştur.
enum Spotlight {
    /// Tam açılımda en çok bu kadar i benzeri harf (2^6 = 64 seçenek).
    static let maxExpandedLetters = 6

    /// Sorgu metni: "*sözcük*" büyük/küçük harf ve aksan duyarsız (`cd`); tırnak, ters bölü ve yıldız kaçışlanır.
    ///
    /// Spotlight büyük/küçük harfi sistem diline göre katlar: Türkçe bir Mac'te dizindeki "I" "ı", "İ" "i" olur;
    /// "isparta" araması "Isparta" geçen belgeyi bulmaz. Kurallar I/ı/İ/i farkını gözetmediği için her i benzeri harf
    /// hem "i" hem "ı" olarak aranır (seçenekler `||` ile). Çok i'li uzun metinlerde seçenek sayısı patlamasın diye
    /// i benzeri harflerin arasındaki parçaların hepsinin geçmesi aranır (`&&`).
    static func query(for text: String) -> String {
        let segments = text.precomposedStringWithCanonicalMapping
            .split(omittingEmptySubsequences: false, whereSeparator: { "iıIİ".contains($0) })
            .map(String.init)
        let parts = segments.filter { !$0.isEmpty }
        if segments.count - 1 > maxExpandedLetters, !parts.isEmpty {
            return combined(parts.map(term), "&&")
        }
        var variants = [segments[0]]
        for segment in segments.dropFirst() {
            variants = variants.flatMap { [$0 + "i" + segment, $0 + "ı" + segment] }
        }
        return combined(variants.map(term), "||")
    }

    private static func term(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
        return "kMDItemTextContent == \"*\(escaped)*\"cd"
    }

    private static func combined(_ terms: [String], _ separator: String) -> String {
        terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " \(separator) ") + ")"
    }

    /// İçinde metnin geçtiği öğelerin kaynağa göre (NFC) göreli yolları.
    static func relativePaths(containing text: String, in root: URL) -> Set<String> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let query = MDQueryCreate(kCFAllocatorDefault, query(for: trimmed) as CFString, nil, nil) else { return [] }
        let rootPath = SandboxProfile.resolved(root).path
        MDQuerySetSearchScope(query, [rootPath] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths = Set<String>()
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, path.hasPrefix(rootPath + "/") else { continue }
            paths.insert(String(path.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping)
        }
        MDQueryStop(query)
        return paths
    }
}
