// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bir aktarımın anlık ilerlemesi (motordan bağımsız). İşle birlikte kaydedilir; uygulama yeniden açılınca son durum
/// gösterilir.
public struct TransferProgress: Codable, Equatable, Sendable {
    /// Bu çalıştırmada aktarılan bayt (rsync `-h` ile yaklaşık değer verir: "29.70K").
    public var bytesTransferred: Int64
    /// 0...1; rsync'in yüzdesi. `isEstimating` doğruyken toplam henüz bilinmediği için kesin değildir.
    public var fraction: Double?
    public var bytesPerSecond: Double?
    /// Kalan süre (saniye); bilinmiyorsa nil. Aktarım bittiğinde rsync bu alana geçen süreyi yazar.
    public var remainingSeconds: Int?
    /// Bu çalıştırmada aktarılan dosya sayısı (`xfr#`).
    public var filesTransferred: Int
    /// Denetlenecek kalan ve bilinen toplam öğe (`to-chk=a/b` ya da `ir-chk=a/b`).
    public var itemsRemaining: Int?
    public var itemsTotal: Int?
    /// rsync dosya listesini hâlâ tarıyor (`ir-chk`): toplam büyüyebilir, yüzde ve kalan süre tahmindir.
    public var isEstimating: Bool

    public init(
        bytesTransferred: Int64 = 0, fraction: Double? = nil, bytesPerSecond: Double? = nil, remainingSeconds: Int? = nil,
        filesTransferred: Int = 0, itemsRemaining: Int? = nil, itemsTotal: Int? = nil, isEstimating: Bool = false
    ) {
        self.bytesTransferred = bytesTransferred
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
        self.remainingSeconds = remainingSeconds
        self.filesTransferred = filesTransferred
        self.itemsRemaining = itemsRemaining
        self.itemsTotal = itemsTotal
        self.isEstimating = isEstimating
    }

    /// Denetlenen öğe sayısı (toplam − kalan).
    public var itemsChecked: Int? {
        guard let itemsTotal, let itemsRemaining else { return nil }
        return max(0, itemsTotal - itemsRemaining)
    }
}

/// rsync `--info=progress2` satırlarını okur.
///
/// Biçim (`progress.c`):
///
///     "         29.70K  81%    0.61kB/s    0:00:47 (xfr#4801, to-chk=1199/6041)"
///     "              0   0%    0.00kB/s    0:00:00 (xfr#0, ir-chk=1050/1091)"
///     "              8   0%    0.00kB/s    0:00:00  "
///
/// Bayt sayısı `-h` ile 1000 tabanlı K/M/G/T/P sonekli ("%.2f"), `-h` olmadan basamak ayırıcılıdır ("1,234,567").
/// Hız 1024 tabanlıdır (kB/s, MB/s, GB/s). Kalan süre bilinmiyorsa "??:??:??" yazılır.
public enum RsyncProgressParser {
    public static func parse<S: StringProtocol>(_ record: S) -> TransferProgress? {
        let tokens = record.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 4,
              let bytes = parseBytes(tokens[0]),
              tokens[1].hasSuffix("%"), let percent = Int(tokens[1].dropLast()), (0...100).contains(percent),
              let rate = parseRate(tokens[2]),
              tokens[3].contains(":") else { return nil }
        var progress = TransferProgress(
            bytesTransferred: bytes, fraction: Double(percent) / 100, bytesPerSecond: rate,
            remainingSeconds: parseDuration(tokens[3])
        )
        // "(xfr#4801," "to-chk=1199/6041)"
        for token in tokens.dropFirst(4) {
            let item = token.trimmingCharacters(in: CharacterSet(charactersIn: "(),"))
            if item.hasPrefix("xfr#"), let count = Int(item.dropFirst(4)), count >= 0 {
                progress.filesTransferred = count
            } else if item.hasPrefix("to-chk=") || item.hasPrefix("ir-chk=") {
                let pair = item.dropFirst(7).split(separator: "/")
                if pair.count == 2, let remaining = Int(pair[0]), let total = Int(pair[1]), remaining >= 0, total >= 0 {
                    progress.itemsRemaining = remaining
                    progress.itemsTotal = total
                    progress.isEstimating = item.hasPrefix("ir-chk=")
                }
            }
        }
        return progress
    }

    /// "29.70K" → 29700, "1,234,567" → 1234567, "0" → 0. Uydurma büyük değerler `Int64.max`'ta durur.
    static func parseBytes<S: StringProtocol>(_ token: S) -> Int64? {
        guard let last = token.last else { return nil }
        let multipliers: [Character: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15]
        if let multiplier = multipliers[last] {
            guard let value = Double(token.dropLast()), value.isFinite, value >= 0 else { return nil }
            return clamp(value * multiplier)
        }
        let digits = String(token.filter { $0 != "," && $0 != "." && $0 != "_" && $0 != "'" })
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(digits) ?? .max
    }

    /// "0.61kB/s" → 624.64, "624.90MB/s" → 655_257_190.4 (1024 tabanlı).
    static func parseRate<S: StringProtocol>(_ token: S) -> Double? {
        let units: [(String, Double)] = [("kB/s", 1024), ("MB/s", 1024 * 1024), ("GB/s", 1024 * 1024 * 1024)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            guard let value = Double(token.dropLast(suffix.count)), value.isFinite, value >= 0 else { return nil }
            return value * multiplier
        }
        return nil
    }

    /// "0:00:47" → 47, "123:04:05" → 443045; "??:??:??" → nil.
    static func parseDuration<S: StringProtocol>(_ token: S) -> Int? {
        let parts = token.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]),
              hours >= 0, hours <= 9999, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func clamp(_ value: Double) -> Int64 {
        value >= Double(Int64.max) ? .max : Int64(value.rounded())
    }
}
