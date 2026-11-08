// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bir rutin çalıştırılmadan (ya da rutine öğe gönderilmeden) önce kurallı rotaların kaynağı taranır: kuralı olan ve
/// hiçbir öğe bulamayan rota kuyruğa girmez. Aynı kaynaktan ve aynı seçili öğelerden okuyan rotalar tek geçişte
/// değerlendirilir (bkz. `RuleScanner.scan(_:sets:)`): on iki rotalı bir rutine verilen tek bir fatura, on iki iş değil
/// yalnızca o faturayı alan rotaların işlerini açar. Kuyruğa giren iş kendi çalıştırmasında kurallarını yeniden uygular.
/// Uygulama ön taramayı en az iki taranabilen aday olduğunda yapar: tek kurallı rotada boş bir iş, aynı kaynağı iki kez
/// taramaktan ucuzdur.
public enum RoutineScan {
    /// Kuyruğa girmeye aday bir rota işi: kaynağı, hedefi ve rotanın iş seçenekleri (`Routine.jobOptions(for:)`).
    public struct Candidate: Sendable {
        public var source: URL
        public var destination: URL
        public var options: CopyOptions

        public init(source: URL, destination: URL, options: CopyOptions) {
            self.source = source
            self.destination = destination
            self.options = options
        }
    }

    /// Önceden taranabilen aday: en az bir kural koşulu var (koşulsuz rota her şeyi kopyalar, büyük bir kaynağı boşuna
    /// taramaya değmez), kaynağı bu Mac'te ya da takılı bir diskte bir klasör ve "hedefte kopyası var" ölçütü kullanılıyorsa
    /// hedefi de erişilebilir. Taranamayan aday her zaman kuyruğa girer: iş diskini bekler ya da sorununu kendi sonucunda
    /// bildirir.
    public static func canScan(_ candidate: Candidate) -> Bool {
        guard let rules = candidate.options.rules, !rules.allConditions.isEmpty else { return false }
        guard VolumeState.unmountedVolume(of: candidate.source) == nil, RsyncEngine.isDirectory(candidate.source) else { return false }
        if rules.allConditions.contains(where: { $0.attribute == .inDestination }) {
            return VolumeState.unmountedVolume(of: candidate.destination) == nil && RsyncEngine.isDirectory(candidate.destination)
        }
        return true
    }

    /// İşi olan adayların indeksleri. Taranamayan adaylar ve taraması hatayla biten adaylar (ör. kaçak düzenli ifade,
    /// okunamayan klasör) da döner: hatayı iş kendi çalıştırmasında bildirir. İptal edilirse `CancellationError` atılır.
    /// - Parameter sandboxHome: Motor kum havuzunda çalışıyorsa ev klasörü; kum havuzunun okutmadığı kişisel klasörler
    ///   motordaki gibi taranmaz (bkz. `RsyncEngine.prepareRules`).
    public static func candidatesWithWork(
        _ candidates: [Candidate], sandboxHome: URL?, now: Date = Date(), isCancelled: () -> Bool = { false }
    ) async throws -> Set<Int> {
        var work = Set(candidates.indices.filter { !canScan(candidates[$0]) })
        // Aynı kök, aynı atlananlar ve aynı seçili öğeler tek geçişte taranır; sıra korunur.
        struct Walk: Hashable {
            var root: String
            var skippedPaths: [String]
            var skipsSystemFolders: Bool
            var skipsWindowsLeftovers: Bool
            var onlyItems: [String]?
        }
        var walks: [Walk] = []
        var members: [Walk: [Int]] = [:]
        for index in candidates.indices where !work.contains(index) {
            let candidate = candidates[index]
            let skipped = sandboxHome.map {
                SandboxProfile.forTransfer(sources: [candidate.source], destination: candidate.destination, home: $0)
                    .protectedPaths(inside: candidate.source)
            } ?? []
            let walk = Walk(root: candidate.source.standardizedFileURL.path, skippedPaths: skipped,
                            skipsSystemFolders: candidate.options.excludeSystemFolders,
                            skipsWindowsLeftovers: candidate.options.excludeWindowsLeftovers,
                            onlyItems: candidate.options.selectedItems?.sorted())
            if members[walk] == nil { walks.append(walk) }
            members[walk, default: []].append(index)
        }
        for walk in walks {
            let indices = members[walk] ?? []
            guard let first = indices.first else { continue }
            let sets = indices.compactMap { index in
                candidates[index].options.rules.map { RuleScanner.RuleSet(rules: $0, destination: candidates[index].destination) }
            }
            do {
                let results = try await RuleScanner.scan(
                    candidates[first].source, sets: sets, skippedPaths: Set(walk.skippedPaths),
                    skippedNames: walk.skipsSystemFolders ? Set(RsyncCommand.systemExclusions) : [],
                    skipsWindowsLeftovers: walk.skipsWindowsLeftovers, now: now, onlyItems: walk.onlyItems.map(Set.init),
                    isCancelled: isCancelled
                )
                for (index, result) in zip(indices, results) where !result.paths.isEmpty { work.insert(index) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                work.formUnion(indices)
            }
        }
        return work
    }
}
