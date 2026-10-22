// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Rotanın seçtiği dosyaların hedefe nasıl yerleşeceği: hedefte alt klasör şablonu (ör. "{year}/{month}-{monthName}")
/// ve ad şablonu (ör. "123456789_El_{month}_{yy}"). İkisi de boşsa kaynağın klasör yapısı ve adları olduğu gibi kalır.
public struct RoutePlacement: Codable, Equatable, Sendable {
    /// Hedefin içindeki alt klasör şablonu; "/" ile alt klasörler. Boşsa kaynağın klasör yapısı korunur.
    public var folderTemplate: String
    /// Klasör şablonu varken kaynağın klasör yapısı da şablonun altında korunsun mu (yoksa dosyalar şablonun klasörüne
    /// düz konur).
    public var keepStructure: Bool
    /// Ad şablonu; boşsa ad değişmez. Uzantı her zaman korunur ve şablona yazılmaz.
    public var nameTemplate: String
    /// Tarih belirteçlerinin ({year}, {month}…) kaynağı.
    public var dateSource: PlacementDateSource
    /// Ay adlarının dili ("tr", "en", "ro"). Şablon kurulurken uygulamanın dili yazılır; arayüz dili sonradan değişse de
    /// klasör adları değişmez.
    public var language: String

    public init(folderTemplate: String = "", keepStructure: Bool = false, nameTemplate: String = "",
                dateSource: PlacementDateSource = .automatic, language: String = "tr") {
        self.folderTemplate = folderTemplate
        self.keepStructure = keepStructure
        self.nameTemplate = nameTemplate
        self.dateSource = dateSource
        self.language = language
    }

    private enum CodingKeys: String, CodingKey { case folderTemplate, keepStructure, nameTemplate, dateSource, language }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderTemplate = (try? c.decodeIfPresent(String.self, forKey: .folderTemplate)) ?? ""
        keepStructure = (try? c.decodeIfPresent(Bool.self, forKey: .keepStructure)) ?? false
        nameTemplate = (try? c.decodeIfPresent(String.self, forKey: .nameTemplate)) ?? ""
        dateSource = (try? c.decodeIfPresent(PlacementDateSource.self, forKey: .dateSource)) ?? .automatic
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? "tr"
    }

    /// Hazır alt klasör şablonları: yıl/ay adı, yıl/ay, yıl.
    public static let folderPresets = ["{year}/{month}-{monthName}", "{year}/{month}", "{year}"]

    /// Şablonlardan biri dolu: dosyalar yerleştirilerek kopyalanır.
    public var isActive: Bool {
        !folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty || !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Şablonlarda bir tarih belirteci var (dosyanın tarihi bulunmalı).
    public var usesDate: Bool {
        PlacementToken.tokens(in: folderTemplate + nameTemplate).contains { $0?.isDate == true }
    }

    public enum Problem: Equatable, Sendable {
        /// Bilinmeyen belirteç ("{yil}").
        case unknownToken(String)
        /// Ad şablonunda "/" (alt klasör klasör şablonuna yazılır).
        case slashInName
        /// Klasör şablonunda "..": hedefin dışına çıkılamaz.
        case parentFolder
    }

    public func problems() -> [Problem] {
        var problems: [Problem] = []
        for (raw, token) in PlacementToken.raw(in: folderTemplate + nameTemplate) where token == nil {
            let problem = Problem.unknownToken(raw)
            if !problems.contains(problem) { problems.append(problem) }
        }
        if nameTemplate.contains("/") { problems.append(.slashInName) }
        if folderTemplate.split(separator: "/").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".." }) {
            problems.append(.parentFolder)
        }
        return problems
    }

    /// Bir dosyanın hedefe göre göreli yolu.
    /// - Parameters:
    ///   - relativePath: Kaynağa göre göreli yol ("2026/Faturalar/fatura.pdf").
    ///   - date: Dosyanın tarihi (yıl ve ay; gün yoksa "01").
    public func target(for relativePath: String, date: DateComponents?) -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        let name = components.last ?? relativePath
        let folders = Array(components.dropLast())
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let values = PlacementToken.values(base: base, folder: folders.last ?? "", date: date, language: language)

        var newName = name
        if !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            var rendered = Self.component(PlacementToken.render(nameTemplate, values))
            if rendered.isEmpty { rendered = base }
            newName = ext.isEmpty ? rendered : rendered + "." + ext
        }
        guard !folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (folders + [newName]).joined(separator: "/")
        }
        let templateFolders = PlacementToken.render(folderTemplate, values).split(separator: "/")
            .map { Self.component(String($0)) }.filter { !$0.isEmpty }
        return (templateFolders + (keepStructure ? folders : []) + [newName]).joined(separator: "/")
    }

    /// Ad ya da klasör adı olarak güvenli metin: "/" ve ":" tireye döner, denetim karakterleri silinir, baştaki boşluk ve
    /// noktalar değer değişmeyene kadar atılır (". .." gibi bir değer ".." bırakıp hedefin dışına çıkmasın; gizli dosya
    /// olmaz), en çok 240 bayt.
    static func component(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        var previous: String
        repeat {
            previous = value
            value = value.trimmingCharacters(in: .whitespaces)
            while value.hasPrefix(".") { value.removeFirst() }
        } while value != previous
        while value.utf8.count > 240 { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// Tarih belirteçlerinin kaynağı.
public enum PlacementDateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Çekim tarihi, yoksa dosya adındaki, yoksa içerikteki tarih, o da yoksa değiştirilme tarihi.
    case automatic
    case fileName
    case contents
    case captureDate
    case modified
    case created

    public var id: String { rawValue }
}

/// Şablon belirteçleri: `{name}` dosyanın uzantısız adı, `{folder}` bulunduğu klasörün adı, `{year}` 2026, `{yy}` 26,
/// `{month}` 01–12, `{monthName}` ay adı (rotanın dilinde), `{day}` 01–31.
public enum PlacementToken: String, CaseIterable, Identifiable, Sendable {
    case name, folder, year, yy, month, monthName, day

    public var id: String { rawValue }
    public var text: String { "{\(rawValue)}" }
    var isDate: Bool { self != .name && self != .folder }

    private static let pattern = try? NSRegularExpression(pattern: "\\{([A-Za-z]+)\\}")

    /// Şablondaki belirteçler (bilinmeyenler nil).
    static func tokens(in template: String) -> [PlacementToken?] { raw(in: template).map(\.1) }

    static func raw(in template: String) -> [(String, PlacementToken?)] {
        guard let pattern else { return [] }
        return pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).compactMap { match in
            guard let whole = Range(match.range, in: template), let name = Range(match.range(at: 1), in: template) else { return nil }
            return (String(template[whole]), PlacementToken(rawValue: String(template[name])))
        }
    }

    static func values(base: String, folder: String, date: DateComponents?, language: String) -> [PlacementToken: String] {
        var values: [PlacementToken: String] = [.name: base, .folder: folder]
        if let date, let year = date.year, let month = date.month {
            values[.year] = String(format: "%04d", year)
            values[.yy] = String(format: "%02d", year % 100)
            values[.month] = String(format: "%02d", month)
            values[.day] = String(format: "%02d", date.day ?? 1)
            values[.monthName] = monthName(month, language: language)
        }
        return values
    }

    /// Ayın adı, dilin kendi yazımıyla ("Ekim", "October", "Octombrie").
    public static func monthName(_ month: Int, language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        let symbols = formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
        guard month >= 1, month <= symbols.count else { return String(format: "%02d", month) }
        let locale = Locale(identifier: language)
        return symbols[month - 1].prefix(1).uppercased(with: locale) + symbols[month - 1].dropFirst()
    }

    /// Belirteçleri değerleriyle değiştirir; bilinmeyen belirteç ve değeri olmayan belirteç olduğu gibi kalmaz, boşalır.
    static func render(_ template: String, _ values: [PlacementToken: String]) -> String {
        var result = ""
        var rest = Substring(template)
        for (raw, token) in raw(in: template) {
            guard let range = rest.range(of: raw) else { continue }
            result += rest[..<range.lowerBound]
            if let token { result += values[token] ?? "" }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

/// Yerleştirilen rotanın kopyası için geçici bir "hazırlık" ağacı: hedefteki düzen (yeni adlar, şablon klasörleri) kaynak
/// dosyalara mutlak sembolik bağlantılarla kurulur ve rsync `--copy-unsafe-links` ile bağlantıların gösterdiği dosyaları
/// kopyalar. Böylece aynı adlı dosya denetimi, "ikisini de sakla", doğrulama, karantina ve sürdürme tek bir rsync
/// çalıştırmasıyla olduğu gibi çalışır. rsync öznitelikleri bağlantının kendisinden okuduğu için kaynağın öznitelikleri
/// (karantina, Finder etiketleri) bağlantılara yazılır. Kaynak yalnızca okunur.
public enum PlacementStaging {
    public struct Result: Sendable {
        public var root: URL
        /// Her seçilen yolun hedefe göre göreli yolu (sırası aynı); atlananlar listede yoktur.
        public var targets: [String]
        /// Hazırlanan (atlanmayan) kaynak yolları.
        public var paths: [String]
        /// Kaynakta sembolik bağlantı olan ya da paket içinde dışarıyı gösteren, kopyalanmayan öğeler.
        public var skippedLinks: Int
    }

    /// - Parameters:
    ///   - paths: Kaynağa göre göreli seçilen yollar (dosyalar ve paketler).
    ///   - folder: Hazırlık ağacının kurulacağı, var olmayan klasör (işin özel geçici klasörünün içinde).
    public static func build(
        paths: [String], source: URL, placement: RoutePlacement, in folder: URL, isCancelled: () -> Bool = { false }
    ) async throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = SandboxProfile.resolved(folder)
        var result = Result(root: root, targets: [], paths: [], skippedLinks: 0)
        var taken = Set<String>()
        for path in paths {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let url = source.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                if kind == S_IFLNK { result.skippedLinks += 1 }
                continue
            }
            let date = placement.usesDate ? await PlacementDate.resolve(url, relativePath: path, source: placement.dateSource) : nil
            var target = placement.target(for: path, date: date)
            // Aynı hedefe düşen iki dosya: sonraki Finder gibi numaralanır ("ad 2.pdf").
            if taken.contains(target.lowercased()) {
                let directory = (target as NSString).deletingLastPathComponent
                let name = ConflictDetector.numberedName(for: (target as NSString).lastPathComponent) { candidate in
                    taken.contains((directory.isEmpty ? candidate : directory + "/" + candidate).lowercased())
                }
                target = directory.isEmpty ? name : directory + "/" + name
            }
            // İkinci savunma: şablon güvenli bileşenler üretir; yine de hedefin dışını gösteren bir yol hiç kurulmaz.
            guard !target.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { continue }
            taken.insert(target.lowercased())
            let staged = root.appendingPathComponent(target)
            try fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == S_IFREG {
                try link(staged, to: url)
            } else {
                result.skippedLinks += try mirror(url, into: staged, isCancelled: isCancelled)
            }
            result.targets.append(target)
            result.paths.append(path)
        }
        // Kaynakta karşılığı olan klasörlerin zamanları kaynağınkiyle aynı olsun (rsync `-t` bunları hedefe yazar).
        copyFolderTimes(root: root, source: source)
        return result
    }

    /// Bağlantı + kaynağın öznitelikleri (bağlantının kendisinde).
    static func link(_ staged: URL, to url: URL) throws {
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: url.path)
        ExtendedAttributes.copy(from: url.path, to: staged.path)
    }

    /// Paket klasörünü (ör. .app) yeniden kurar: klasörler gerçek, dosyalar bağlantı. Paketin içinde kalan göreli
    /// bağlantılar ("Versions/Current → A") aynen kurulur ve rsync onları bağlantı olarak kopyalar; paketin dışını
    /// gösterenler kurulmaz (rsync onları izleyip içeriklerini kopyalardı). - Returns: Kurulmayan bağlantı sayısı.
    static func mirror(_ folder: URL, into staged: URL, isCancelled: () -> Bool) throws -> Int {
        let fileManager = FileManager.default
        var skipped = 0
        var directories: [(URL, URL)] = [(folder, staged)]
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        var queue = [(folder, staged, 0)]
        while let (current, target, depth) = queue.popLast() {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            for name in try fileManager.contentsOfDirectory(atPath: current.path) {
                let item = current.appendingPathComponent(name)
                let copy = target.appendingPathComponent(name)
                var info = stat()
                guard lstat(item.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    try fileManager.createDirectory(at: copy, withIntermediateDirectories: false)
                    directories.append((item, copy))
                    queue.append((item, copy, depth + 1))
                case S_IFREG:
                    try link(copy, to: item)
                case S_IFLNK:
                    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path),
                          staysInside(destination, at: depth) else {
                        skipped += 1
                        continue
                    }
                    try fileManager.createSymbolicLink(atPath: copy.path, withDestinationPath: destination)
                default:
                    continue
                }
            }
        }
        for (original, copy) in directories {
            ExtendedAttributes.copy(from: original.path, to: copy.path)
            copyTimes(from: original.path, to: copy.path)
        }
        return skipped
    }

    /// Göreli bağlantı, `depth` düzey içerideki konumundan paketin köküne çıkmadan çözülüyor mu?
    static func staysInside(_ destination: String, at depth: Int) -> Bool {
        guard !destination.hasPrefix("/") else { return false }
        var level = depth
        for component in destination.split(separator: "/") {
            if component == ".." { level -= 1 } else if component != "." { level += 1 }
            if level < 0 { return false }
        }
        return true
    }

    /// Hazırlık ağacında kaynaktaki bir klasöre karşılık gelen klasörlerin zamanlarını kaynaktan alır.
    static func copyFolderTimes(root: URL, source: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                              options: [.producesRelativePathURLs]) else { return }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let original = source.appendingPathComponent(url.relativePath)
            var originalInfo = stat()
            if lstat(original.path, &originalInfo) == 0, originalInfo.st_mode & S_IFMT == S_IFDIR {
                copyTimes(from: original.path, to: url.path)
            }
        }
    }

    static func copyTimes(from source: String, to target: String) {
        var info = stat()
        guard lstat(source, &info) == 0 else { return }
        var times = [info.st_atimespec, info.st_mtimespec]
        _ = utimensat(AT_FDCWD, target, &times, AT_SYMLINK_NOFOLLOW)
    }
}

/// Dosyanın şablon tarihini bulur (bkz. `PlacementDateSource`).
public enum PlacementDate {
    public static func resolve(_ url: URL, relativePath: String, source: PlacementDateSource) async -> DateComponents {
        let calendar = Calendar(identifier: .gregorian)
        func components(_ date: Date?) -> DateComponents? {
            date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        let name = (relativePath as NSString).lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modified = components(values?.contentModificationDate) ?? calendar.dateComponents([.year, .month, .day], from: Date())
        func capture() async -> DateComponents? {
            guard let type, type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { return nil }
            return components(await MediaInfo.load(url, type: type)?.captureDate)
        }
        func contents() -> DateComponents? { ContentReader.text(of: url, type: type).flatMap(TextDate.find) }
        switch source {
        case .automatic:
            if let date = await capture() { return date }
            if let date = TextDate.find(in: (name as NSString).deletingPathExtension) { return date }
            if let date = contents() { return date }
            return modified
        case .fileName: return TextDate.find(in: (name as NSString).deletingPathExtension) ?? modified
        case .contents: return contents() ?? modified
        case .captureDate: return await capture() ?? modified
        case .modified: return modified
        case .created: return components(values?.creationDate) ?? modified
        }
    }
}

/// Genişletilmiş öznitelikleri (karantina, Finder etiketleri, yorumlar…) bir öğeden ötekine kopyalar; bağlantı izlenmez.
enum ExtendedAttributes {
    static func copy(from source: String, to target: String) {
        let size = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source, &names, size, XATTR_NOFOLLOW) == size else { return }
        for name in names.split(separator: 0, omittingEmptySubsequences: true).map({ Array($0) + [0] }) {
            let length = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: length)
            guard getxattr(source, name, &value, length, 0, XATTR_NOFOLLOW) == length else { continue }
            _ = setxattr(target, name, value, length, 0, XATTR_NOFOLLOW)
        }
    }
}
