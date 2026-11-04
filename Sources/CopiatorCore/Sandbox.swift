// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// rsync'i çekirdek kum havuzunda (sandbox-exec) çalıştırma kuralları.
///
/// Yerel kopyalamada rsync'in ağa ihtiyacı yoktur: ağ her zaman kapalıdır. Yalnızca işin hedefine yazabilir; kaynak
/// hedefin içinde olsa bile salt okunurdur (bir `--delete` ya da hatalı bir argüman kaynağı değiştiremez). Kişisel gizli
/// veri klasörleri (~/.ssh, Keychains, tarayıcı profilleri…) kullanıcı açıkça kaynak olarak seçmedikçe okunamaz.
public struct SandboxProfile: Sendable, Equatable {
    public var writableDirectories: [URL]
    /// Yazılabilir bir klasörün içinde olsa da yazılamayan klasörler: işin kaynakları. SBPL'de son eşleşen kural
    /// kazandığı için yasak, yazma izninden SONRA yazılır.
    public var readOnlyDirectories: [URL]
    public var deniedReadDirectories: [URL]
    /// Yasaklı bir klasörün içinde olsa da okunabilir tek dosyalar (kullanıcının seçtiği dosya kaynağı).
    public var readableFiles: [URL]
    /// Yasaklı bir klasörün içindeki (ya da kendisi olan), kullanıcının açıkça seçtiği kaynak klasörler.
    public var readableDirectories: [URL]
    /// Yazılabilir tek dosyalar (iş başına seçilen günlük ve toplu iş dosyaları).
    public var writableFiles: [URL]

    /// sandbox-exec'in yolu; testler var olmayan bir yol vererek başlatıcının bulunmadığı bir Mac'i taklit eder.
    @TaskLocal public static var launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
    }

    public init(
        writableDirectories: [URL], readOnlyDirectories: [URL] = [], deniedReadDirectories: [URL],
        readableFiles: [URL] = [], readableDirectories: [URL] = [], writableFiles: [URL] = []
    ) {
        self.writableFiles = writableFiles
        self.writableDirectories = writableDirectories
        self.readOnlyDirectories = readOnlyDirectories
        self.deniedReadDirectories = deniedReadDirectories
        self.readableFiles = readableFiles
        self.readableDirectories = readableDirectories
    }

    /// Kimlik bilgisi ve kişisel veri taşıyan klasörler. Sabit liste eksiksiz olamaz; en yaygın gizli konumlar.
    public static func personalDataDirectories(home: URL) -> [URL] {
        [
            // Kimlik bilgileri ve erişim belirteçleri
            ".ssh", ".gnupg", ".aws", ".config/gh", ".netrc", ".kube", ".docker", ".npmrc", ".pypirc", ".git-credentials",
            // Bulut ve geliştirici kimlik bilgileri
            ".config/gcloud", ".azure", ".oci", ".terraform.d", ".m2", ".gradle", ".cargo", ".gem", ".config/Code", "Library/Application Support/Code",
            // Kabuk geçmişi (komut satırına yazılmış parolalar, belirteçler)
            ".zsh_history", ".bash_history",
            // Sistem ve iletişim verileri
            "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages",
            "Library/Application Support/AddressBook", "Library/Safari", "Library/Accounts",
            // Uygulama kapları ve HTTP oturumları (sandbox'lı uygulamaların verileri, çerezleri)
            "Library/Containers", "Library/Group Containers", "Library/HTTPStorages",
            // Tarayıcı profilleri (çerezler, kayıtlı parolalar, oturumlar)
            "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
            "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
            "Library/Application Support/Arc", "Library/Application Support/Vivaldi",
            "Library/Application Support/com.operasoftware.Opera",
        ].map { home.appendingPathComponent($0) }
    }

    /// Bir kopyalama işi için kurallar.
    /// - Parameters:
    ///   - sources: Kopyalanan öğeler. Salt okunur kalırlar. Kişisel bir klasörün içindeyse (ya da kendisiyse) o klasör
    ///     yasaklı KALIR, yalnızca seçilen kaynak (klasörse içeriğiyle) yasaktan sonra gelen bir izinle okunur.
    ///   - destination: rsync'in yazacağı tek klasör.
    ///   - protectPersonalData: false ise kişisel veri klasörleri yasaklanmaz.
    ///   - extraReadable: İşin okuması gereken ek yollar (`--files-from` listesi, `--link-dest` önceki yedeği…).
    ///   - extraWritableFiles: İşin yazması gereken tek dosyalar (`--log-file`, `--write-batch` ve `.sh` betiği).
    ///   - extraWritableDirectories: Hedefin dışındaki yedek klasörü (`--backup-dir`).
    public static func forTransfer(
        sources: [URL], destination: URL, protectPersonalData: Bool = true,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraReadable: [URL] = [], extraWritableFiles: [URL] = [], extraWritableDirectories: [URL] = []
    ) -> SandboxProfile {
        let destination = resolved(destination)
        let sources = sources.map(resolved)
        let denied = protectPersonalData
            ? personalDataDirectories(home: home).map(resolved).filter { denied in
                // Hedefi kapsayan bir yasak işlemi bozardı (kullanıcı hedefi bilerek seçti).
                !(destination.path == denied.path || destination.path.hasPrefix(denied.path + "/"))
            }
            : []
        var readableFiles: [URL] = []
        var readableDirectories: [URL] = []
        // Seçilen kaynaklar ve iş başına seçilen ek okuma yolları (liste dosyaları, önceki yedek): yasaklı bir klasörün
        // içindeyseler yalnızca kendileri izinlidir.
        for source in sources + extraReadable.map(resolved)
        where denied.contains(where: { source.path == $0.path || source.path.hasPrefix($0.path + "/") }) {
            var info = stat()
            if stat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                readableDirectories.append(source)
            } else {
                readableFiles.append(source)
            }
        }
        // Kaynağın içine düşen ek yazma yolları verilmez: kaynak her durumda salt okunurdur (yasak izinden sonra gelir).
        return SandboxProfile(
            writableDirectories: [destination] + extraWritableDirectories.map(resolved), readOnlyDirectories: sources,
            deniedReadDirectories: denied, readableFiles: readableFiles, readableDirectories: readableDirectories,
            writableFiles: extraWritableFiles.map(resolved)
        )
    }

    /// Kaynağın içinde kalan ve kum havuzunun okutmayacağı kişisel klasörler (kaynağa göre göreli yollar).
    /// Örneğin ev klasörünün tamamı yedeklenirken ~/.ssh atlanır; rsync'e bunlar baştan dışlama olarak verilir, yoksa
    /// her biri için "Operation not permitted" hatası ve "bazı dosyalar aktarılamadı" sonucu üretirdi.
    public func protectedPaths(inside source: URL) -> [String] {
        let root = Self.resolved(source).path
        return deniedReadDirectories.compactMap { denied in
            guard denied.path.hasPrefix(root + "/") else { return nil }
            // Açıkça seçilen bir kaynak bu yasak klasörün içindeyse o kaynak zaten izinlidir; yasak klasör yine dışlanır.
            return String(denied.path.dropFirst(root.count + 1))
        }.sorted()
    }

    /// Sembolik bağlantıları çöz (/tmp → /private/tmp, /var → /private/var); çekirdek gerçek yolları denetler.
    /// `URL.resolvingSymlinksInPath()` baştaki "/private" kısmını sildiği için `realpath(3)` kullanılır.
    /// Henüz var olmayan yollar için var olan en yakın üst klasör çözülür.
    public static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing
        if let real = realpath(existing.path, nil) {
            result = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in suffix { result.appendPathComponent(component) }
        return result
    }

    /// SBPL kuralları. Yollar `-D` parametreleriyle verilir; tırnak ya da kaçış sorunu olmaz.
    public var profileText: String {
        var lines = ["(version 1)", "(allow default)", "(deny network*)", "(deny file-write*)"]
        let writes = ["(subpath \"/dev\")"] + writableDirectories.indices.map { "(subpath (param \"W\($0)\"))" }
            + writableFiles.indices.map { "(literal (param \"A\($0)\"))" }
        lines.append("(allow file-write* \(writes.joined(separator: " ")))")
        // Kaynaklar, hedefin içinde olsalar bile salt okunur: yasak izinden SONRA gelir (son eşleşen kural kazanır).
        if !readOnlyDirectories.isEmpty {
            let sources = readOnlyDirectories.indices.map { "(subpath (param \"K\($0)\"))" }
            lines.append("(deny file-write* \(sources.joined(separator: " ")))")
        }
        if !deniedReadDirectories.isEmpty {
            let reads = deniedReadDirectories.indices.map { "(subpath (param \"R\($0)\"))" }
            lines.append("(deny file-read* \(reads.joined(separator: " ")))")
        }
        // Yasaklı klasördeki, kullanıcının seçtiği kaynaklar: izin yasaktan SONRA gelir.
        if !readableFiles.isEmpty {
            let files = readableFiles.indices.map { "(literal (param \"F\($0)\"))" }
            lines.append("(allow file-read* \(files.joined(separator: " ")))")
        }
        if !readableDirectories.isEmpty {
            let directories = readableDirectories.indices.map { "(subpath (param \"S\($0)\"))" }
            lines.append("(allow file-read* \(directories.joined(separator: " ")))")
        }
        // Ele geçirilmiş bir rsync başka program çalıştıramaz ve mach servislerine (AppleEvents, launchd) ulaşamaz.
        // Yerel kopyalamada rsync 3.x kendini çatallar (fork); openrsync kendini yeniden çalıştırır (exec), bu yüzden ona
        // kendi yolu `--rsync-path` ile verilir. Her iki durumda da yalnızca motorun kendisi izinlidir.
        lines.append("(deny mach-lookup)")
        lines.append("(deny process-exec)")
        lines.append("(allow process-exec (literal (param \"E\")))")
        return lines.joined(separator: "\n")
    }

    /// sandbox-exec'e verilecek argümanlar: profil, parametreler, ardından asıl program ve argümanları.
    public func launchArguments(executable: URL, arguments: [String]) -> [String] {
        var result = ["-p", profileText]
        for (index, url) in writableDirectories.enumerated() { result += ["-D", "W\(index)=\(url.path)"] }
        for (index, url) in writableFiles.enumerated() { result += ["-D", "A\(index)=\(url.path)"] }
        for (index, url) in readOnlyDirectories.enumerated() { result += ["-D", "K\(index)=\(url.path)"] }
        for (index, url) in deniedReadDirectories.enumerated() { result += ["-D", "R\(index)=\(url.path)"] }
        for (index, url) in readableFiles.enumerated() { result += ["-D", "F\(index)=\(url.path)"] }
        for (index, url) in readableDirectories.enumerated() { result += ["-D", "S\(index)=\(url.path)"] }
        // Çekirdek gerçek yolu denetler: bağlantı üzerinden verilen bir motor yolu da çözülür.
        result += ["-D", "E=\(Self.resolved(executable).path)"]
        return result + [executable.path] + arguments
    }
}

extension CommandRunner {
    /// Bu çalıştırıcının kum havuzunda çalışan kopyası. sandbox-exec bulunmasa da kurallar kalır: o zaman çalıştırma
    /// `EngineError.sandboxUnavailable` ile reddedilir, program korumasız başlatılmaz.
    public func sandboxed(_ profile: SandboxProfile?) -> CommandRunner {
        guard let profile else { return self }
        return CommandRunner(executableURL: executableURL, sandbox: profile)
    }
}
