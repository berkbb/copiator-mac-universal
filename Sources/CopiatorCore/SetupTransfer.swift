// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// İşleri ve ayarları başka bir Mac'e taşıma. Dosya sürümlü bir JSON'dur: her iş yalnızca türü, kaynağı, hedefi ve
/// seçenekleriyle yazılır (geçmiş, günlük, sonuç, ilerleme ve rutin bağı yazılmaz). İçe aktarılan işler yeni kimlik alır
/// ve duraklatılmış gelir: hiçbiri kendiliğinden başlamaz. Ayarlar uygulamanın seçtiği taşınabilir alanlardır
/// (`Settings`); bu Mac'te bulunmayan klasörler içe aktarmadan önce yeniden eşlenebilir.
public enum SetupTransfer {
    public static let format = "copiator-setup"
    public static let version = 1
    /// İçe aktarılan dosyanın en büyük boyutu.
    public static let maxSize = 10_000_000

    struct PortableJob: Codable {
        var kind: JobKind
        var source: URL
        var destination: URL
        var options: CopyOptions
    }

    struct Archive<Settings: Codable>: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var jobs: [PortableJob]
        var settings: Settings?
    }

    public struct Contents<Settings> {
        public var jobs: [TransferJob]
        public var settings: Settings?
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Copiator kurulum dosyası değil ya da bozuk.
        case notSetup
        /// Daha yeni bir sürümün dosyası.
        case newerVersion(Int)
        /// Çok büyük.
        case tooLarge
    }

    /// Bu Mac'te bulunmayan bir iş klasörü.
    public struct Missing: Equatable, Hashable, Sendable, Identifiable {
        public var job: UUID
        public var isSource: Bool
        public var url: URL
        public var id: String { "\(job.uuidString)-\(isSource)" }
    }

    public static func export<Settings: Codable>(jobs: [TransferJob], settings: Settings?, now: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let portable = jobs.map { PortableJob(kind: $0.kind, source: $0.source, destination: $0.destination, options: $0.options) }
        return try encoder.encode(Archive(format: format, version: version, exportedAt: now, jobs: portable, settings: settings))
    }

    /// Dosyadaki işler ve ayarlar, içe aktarmaya hazır: yeni kimlikler, duraklatılmış, geçmişsiz.
    public static func read<Settings: Codable>(_ data: Data, settings: Settings.Type, now: Date = Date()) throws -> Contents<Settings> {
        guard data.count <= maxSize else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let head = try? decoder.decode(Head.self, from: data), head.format == format else { throw Failure.notSetup }
        guard head.version <= version else { throw Failure.newerVersion(head.version) }
        guard let archive = try? decoder.decode(Archive<Settings>.self, from: data) else { throw Failure.notSetup }
        let jobs = archive.jobs.map {
            TransferJob(kind: $0.kind, source: $0.source, destination: $0.destination, options: $0.options, status: .paused, createdAt: now)
        }
        return Contents(jobs: jobs, settings: archive.settings)
    }

    /// Biçim ve sürüm: daha yeni bir dosyanın geri kalanı bu sürümde çözülemese de nedeni söylenebilsin.
    private struct Head: Decodable {
        var format: String
        var version: Int
    }

    /// Bu Mac'te bulunmayan kaynak ve hedef klasörler.
    public static func missingFolders(in jobs: [TransferJob], fileManager: FileManager = .default) -> [Missing] {
        jobs.flatMap { job in
            [(true, job.source), (false, job.destination)].compactMap { isSource, url in
                fileManager.fileExists(atPath: url.path) ? nil : Missing(job: job.id, isSource: isSource, url: url)
            }
        }
    }

    /// Bir klasörü yeniden eşler (işin kaynağı ya da hedefi).
    public static func remap(_ missing: Missing, to url: URL, in jobs: inout [TransferJob]) {
        guard let index = jobs.firstIndex(where: { $0.id == missing.job }) else { return }
        if missing.isSource { jobs[index].source = url } else { jobs[index].destination = url }
    }
}
