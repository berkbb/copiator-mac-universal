// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// rsync çıkış kodunu ve hata çıktısını, kullanıcıya gösterilecek bir sonuç sınıfına çevirir.
///
/// rsync çıkış kodları (`errcode.h`): 0 başarı, 1 sözdizimi, 4 desteklenmeyen işlem, 11 dosya G/Ç, 12 veri akışı,
/// 20 SIGINT/SIGTERM, 23 bazı dosyalar/öznitelikler aktarılamadı, 24 kaynak dosyalar kayboldu, 30 zaman aşımı.
public enum RsyncOutcome {
    /// exFAT/FAT hedefin saklayamadığı bilgi yüzünden gelen uyarılar. Bu birimlerde zararsızdır: dosyanın içeriği
    /// kopyalanmıştır, yalnızca izin, sahip, ACL, öznitelik ya da zaman damgası yazılamamıştır. İfadeler yalnızca
    /// iletinin başında aranır (bkz. `messageBody`), dosya adında değil: "chown notlar.txt" adlı bir dosyanın
    /// yazılamaması zararsız sayılmaz.
    static let harmlessAttributePrefixes = [
        "failed to set times on ", "failed to set permissions on ", "failed to modify permissions on ",
        "set_acl: ", "rsync_xal_set: ", "chown \"", "chgrp \"",
        "uid 4294967295 (-1) is impossible to set on ", "gid 4294967295 (-1) is impossible to set on ",
    ]

    /// "rsync: [receiver] failed to set times on …" → "failed to set times on …". rsync iletileri "rsync: " ve isteğe
    /// bağlı bir "[rol] " önekiyle başlar; dosya adı her zaman iletinin içinde tırnaklı gelir.
    static func messageBody<S: StringProtocol>(of line: S) -> Substring {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("rsync: ") { text = text.dropFirst("rsync: ".count) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = text[text.index(after: close)...].drop(while: { $0 == " " })
        }
        return text
    }

    /// Satır, aktarılamayan bir dosyayı ya da işlemi bildiren bir rsync hatası mı? Özet satırı ("rsync error: …")
    /// ve rsync'in bilgi satırları sayılmaz.
    static func isErrorLine<S: StringProtocol>(_ line: S) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("rsync error:") || text.hasPrefix("rsync warning:") { return false }
        return text.hasPrefix("rsync:") || text.hasPrefix("file has vanished:") || text.hasPrefix("ERROR:")
    }

    static func isHarmlessAttributeWarning<S: StringProtocol>(_ line: S) -> Bool {
        let body = messageBody(of: line)
        return harmlessAttributePrefixes.contains { body.hasPrefix($0) }
    }

    /// - Parameters:
    ///   - exitCode: rsync'in çıkış kodu.
    ///   - stderr: rsync'in hata çıktısı.
    ///   - destinationFileSystem: Hedefin dosya sistemi; öznitelik uyarıları yalnızca exFAT/FAT/NTFS'de zararsızdır.
    public static func classify(exitCode: Int32, stderr: String, destinationFileSystem: FileSystemKind) -> JobResult {
        let lines = stderr.split(whereSeparator: \.isNewline)
        let errors = lines.filter(isErrorLine)
        let detail = EngineError.diagnostic(from: stderr)

        switch exitCode {
        case 0:
            return JobResult(kind: .succeeded, exitCode: 0)
        case 20:
            return JobResult(kind: .cancelled, exitCode: exitCode, detail: detail)
        case 30 where lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "stopping at requested limit" }):
            // `--stop-at` / `--stop-after` sınırı: rsync zaman aşımıyla aynı kodla çıkar, ama iş sürdürülebilir.
            return JobResult(kind: .stoppedAtLimit, exitCode: exitCode, detail: detail)
        case 24:
            // Kaynaktaki bazı dosyalar kopyalanırken silindi ya da taşındı (canlı klasörlerde olağan). Başka hata da
            // varsa 23 dönerdi; geri kalan her şey kopyalanmıştır.
            return JobResult(kind: .sourceFilesVanished, exitCode: exitCode, noteCount: errors.count, detail: detail)
        default:
            break
        }

        // Hedef doldu (ENOSPC 28) ya da kota aşıldı (EDQUOT 69), birim salt okunur (EROFS 30): hangi kodla bittiği
        // önemli değil. rsync errno metnini satırın SONUNA yazar ("…failed: No space left on device (28)"); dosya adı
        // tırnak içinde önce gelir, bu yüzden yalnızca satır sonuna bakılır.
        if lines.contains(where: { endsWithErrno($0, ["No space left on device (28)", "Disc quota exceeded (69)", "Disk quota exceeded (69)"]) }) {
            return JobResult(kind: .destinationFull, exitCode: exitCode, detail: detail)
        }
        if lines.contains(where: { endsWithErrno($0, ["Read-only file system (30)"]) }) {
            return JobResult(kind: .destinationReadOnly, exitCode: exitCode, detail: detail)
        }

        if exitCode == 23 {
            // Tüm hatalar exFAT/FAT'in saklayamadığı öznitelik uyarılarıysa iş başarılıdır; tek bir bilgi satırı gösterilir.
            if destinationFileSystem.lacksPosixMetadata, !errors.isEmpty, errors.allSatisfy(isHarmlessAttributeWarning) {
                return JobResult(kind: .succeededWithNotes, exitCode: exitCode, noteCount: errors.count, detail: detail)
            }
            let serious = errors.filter { !destinationFileSystem.lacksPosixMetadata || !isHarmlessAttributeWarning($0) }
            // Kaynağın kendisi yok: "link_stat ... failed: No such file or directory" ve başka hata yok.
            if !serious.isEmpty, serious.allSatisfy({
                messageBody(of: $0).hasPrefix("link_stat ") && endsWithErrno($0, ["No such file or directory (2)"])
            }) {
                return JobResult(kind: .sourceMissing, exitCode: exitCode, detail: detail)
            }
            if !serious.isEmpty, serious.allSatisfy({ endsWithErrno($0, ["Permission denied (13)", "Operation not permitted (1)"]) }) {
                return JobResult(kind: .permissionDenied, exitCode: exitCode, noteCount: serious.count, detail: detail)
            }
            return JobResult(kind: .partial, exitCode: exitCode, noteCount: serious.count, detail: detail)
        }

        switch exitCode {
        case 1, 2, 4: return JobResult(kind: .unsupported, exitCode: exitCode, detail: detail)
        case 3: return JobResult(kind: .sourceMissing, exitCode: exitCode, detail: detail)
        case 11, 12, 13, 14, 30, 35: return JobResult(kind: .ioError, exitCode: exitCode, detail: detail)
        default: return JobResult(kind: .failed, exitCode: exitCode, detail: detail)
        }
    }

    static func endsWithErrno<S: StringProtocol>(_ line: S, _ messages: [String]) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return messages.contains { text.hasSuffix(": " + $0) }
    }

    /// Günlüğe yazılacak ham hata satırları (zararsız uyarılar hariç), en çok `limit` satır.
    public static func errorLines(in stderr: String, destinationFileSystem: FileSystemKind, limit: Int = 50) -> [String] {
        stderr.split(whereSeparator: \.isNewline)
            .filter(isErrorLine)
            .filter { !destinationFileSystem.lacksPosixMetadata || !isHarmlessAttributeWarning($0) }
            .prefix(limit)
            .map { OpenSafety.visibleName($0.trimmingCharacters(in: .whitespaces)) }
    }
}
