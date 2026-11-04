// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Tanılama maskeleyicisi (uydurma kullanıcı "kullanici", tam adı "Ada Örnek"): ev klasörü "~", kullanıcı adları ‹user›,
/// disk, klasör ve dosya adları rapor içinde tutarlı ama geri çözülemez özetler olur; standart klasör adları, anlık
/// görüntü adları ve kısa uzantılar açık kalır.
struct DiagnosticMaskerTests {
    private let masker = DiagnosticMasker(home: "/Users/kullanici", userNames: ["kullanici", "Ada Örnek"], salt: Data([1, 2, 3]))

    @Test func pathsKeepStructureAndHideNames() {
        let masked = masker.path("/Users/kullanici/Documents/Fatura Ekim.pdf")
        #expect(masked.hasPrefix("~/Documents/‹name-") && masked.hasSuffix("›.pdf"))
        #expect(!masked.contains("Fatura") && !masked.contains("kullanici"))
        let volume = masker.path("/Volumes/Yedek Diski/Arsiv/2026-11-02-100000/Latest")
        #expect(volume.hasPrefix("/Volumes/‹name-") && volume.hasSuffix("/2026-11-02-100000/Latest"))
        #expect(!volume.contains("Yedek") && !volume.contains("Arsiv"))
        #expect(masker.path("/Users/kullanici") == "~")
        #expect(masker.path("/Users/kullaniciX/a").hasPrefix("/Users/‹name-"), "ev klasörünün yalnızca adı benzeyen klasör")
        // Aynı ad aynı özeti alır; tuz değişince özet değişir.
        #expect(masker.name("Arsiv") == masker.name("Arsiv") && masker.name("Arsiv") != masker.name("Arsiv2"))
        #expect(DiagnosticMasker(home: "/Users/kullanici", userNames: [], salt: Data([9])).name("Arsiv") != masker.name("Arsiv"))
        // Uzun ya da harf/rakam olmayan uzantılar ve gizli dosyaların "uzantısı" saklanmaz.
        #expect(!masker.name("notlar.gizliuzanti12").contains("gizliuzanti12"))
        #expect(!masker.name(".zshrc").contains("zshrc"))
        #expect(masker.name("2026-11-02-100000.partial") == "2026-11-02-100000.partial")
    }

    @Test func freeTextHidesUsersQuotedAndBareNames() {
        let line = #"rsync: [sender] send_files failed to open "/Users/kullanici/Belgeler/Gizli Proje.docx": Permission denied (13)"#
        let masked = masker.text(line)
        #expect(masked.hasPrefix(#"rsync: [sender] send_files failed to open "~/‹name-"#))
        #expect(masked.hasSuffix(#".docx": Permission denied (13)"#))
        #expect(!masked.contains("Gizli") && !masked.contains("Belgeler") && !masked.contains("kullanici"))
        // Uygulamanın kendi metinleri: kıvrık tırnak içindeki ad, tırnaksız yol, kullanıcı adları, kesme işaretleri.
        let app = masker.text("“Tatil Fotoğrafları” kopyalandı: /Volumes/Yedek/Arsiv. Ada Örnek ve ADA burada; Copiator'ı rsync'in açtığı")
        #expect(!app.contains("Tatil") && !app.contains("Yedek") && !app.contains("Arsiv"))
        #expect(!app.contains("Ada") && !app.contains("Örnek") && !app.contains("ADA"))
        #expect(app.contains("‹user›") && app.contains("Copiator'ı rsync'in açtığı"))
        // Bilinen yollar boşluk içerse de bütün olarak maskelenir.
        let known = masker.text("Kaynak /Volumes/Dış Disk/Fotoğraf Arşivi bulunamadı", knownPaths: ["/Volumes/Dış Disk/Fotoğraf Arşivi"])
        #expect(!known.contains("Dış") && !known.contains("Arşivi") && known.hasSuffix(" bulunamadı"))
        // Adresler ve sayılar bozulmaz.
        #expect(masker.text("https://github.com/x 23/24 \"12\"") == "https://github.com/x 23/24 \"12\"")
    }

    @Test func commandArgumentsHidePathsAndPatterns() {
        #expect(masker.argument("-rltDh") == "-rltDh")
        #expect(masker.argument("--info=progress2") == "--info=progress2")
        #expect(masker.argument("--exclude=Muhasebe *.xlsx") == "--exclude=‹pattern›")
        #expect(masker.argument("--suffix=.yedek") == "--suffix=‹pattern›")
        let anchored = masker.argument("--exclude=/Belgeler/.ssh")
        #expect(anchored.hasPrefix("--exclude=/‹name-") && anchored.hasSuffix("/.ssh"))
        let list = masker.argument("--exclude-from=/Users/kullanici/liste.txt")
        #expect(list.hasPrefix("--exclude-from=~/‹name-") && list.hasSuffix(".txt"))
        let source = masker.argument("/Users/kullanici/Belgeler/")
        #expect(source.hasPrefix("~/‹name-") && source.hasSuffix("/"))
    }
}
