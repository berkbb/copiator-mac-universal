// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Rutinleri bir dosyaya dışa aktarma ve başka bir Mac'te içe aktarma. Dosya sürümlü bir JSON'dur; içe aktarılan rutinler
/// ve rotaları yeni kimlik alır (var olanlarla ve işleriyle çakışmaz), aynı adlı rutin varsa ada sıra numarası eklenir,
/// öğrenilmiş klasörler ve yerleşim korunur. Bu Mac'te bulunmayan klasörler içe aktarmadan önce yeniden eşlenebilir.
public enum RoutineTransfer {
    public static let format = "copiator-routines"
    public static let version = 1
    /// İçe aktarılan dosyanın en büyük boyutu.
    public static let maxSize = 10_000_000

    struct Archive: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var routines: [Routine]
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Copiator rutin dosyası değil ya da bozuk.
        case notRoutines
        /// Daha yeni bir sürümün dosyası.
        case newerVersion(Int)
        /// Çok büyük.
        case tooLarge
    }

    /// Bu Mac'te bulunmayan bir rota klasörü.
    public struct Missing: Equatable, Hashable, Sendable, Identifiable {
        public var routine: UUID
        public var route: UUID
        public var isSource: Bool
        public var url: URL
        public var id: String { "\(route.uuidString)-\(isSource)" }
    }

    public static func export(_ routines: [Routine], now: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(format: format, version: version, exportedAt: now, routines: routines))
    }

    /// Dosyadaki rutinler, içe aktarmaya hazır: yeni kimlikler, son çalıştırma yok, çakışan adlara sıra numarası.
    public static func read(_ data: Data, existingNames: Set<String>, now: Date = Date()) throws -> [Routine] {
        guard data.count <= maxSize else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data), archive.format == format else { throw Failure.notRoutines }
        guard archive.version <= version else { throw Failure.newerVersion(archive.version) }
        var taken = Set(existingNames.map { $0.lowercased() })
        return archive.routines.map { original in
            var routine = original
            routine.id = UUID()
            routine.routes = routine.routes.map { route in
                var route = route
                route.id = UUID()
                return route
            }
            routine.lastRunAt = nil
            routine.createdAt = now
            routine.updatedAt = now
            var name = routine.name
            var number = 2
            while taken.contains(name.lowercased()) {
                name = "\(routine.name) (\(number))"
                number += 1
            }
            routine.name = name
            taken.insert(name.lowercased())
            return routine
        }
    }

    /// Bu Mac'te bulunmayan kaynak ve hedef klasörler.
    public static func missingFolders(in routines: [Routine], fileManager: FileManager = .default) -> [Missing] {
        routines.flatMap { routine in
            routine.routes.flatMap { route -> [Missing] in
                [(true, route.source), (false, route.destination)].compactMap { isSource, url in
                    guard let url, !fileManager.fileExists(atPath: url.path) else { return nil }
                    return Missing(routine: routine.id, route: route.id, isSource: isSource, url: url)
                }
            }
        }
    }

    /// Bir klasörü yeniden eşler (rotanın kaynağı ya da hedefi).
    public static func remap(_ missing: Missing, to url: URL, in routines: inout [Routine]) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == missing.routine }),
              let routeIndex = routines[routineIndex].routes.firstIndex(where: { $0.id == missing.route }) else { return }
        if missing.isSource { routines[routineIndex].routes[routeIndex].source = url } else { routines[routineIndex].routes[routeIndex].destination = url }
    }
}
