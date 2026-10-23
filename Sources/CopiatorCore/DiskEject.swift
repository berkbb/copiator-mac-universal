// SPDX-License-Identifier: GPL-3.0-or-later
import DiskArbitration
import Foundation

/// "Bitince hedef diski çıkar": başarılı bir çalıştırmadan sonra hedefin bulunduğu disk, o diskte (aynı fiziksel disk ya da
/// APFS kabındaki öteki birimlerde) bekleyen, çalışan ya da karar bekleyen bir iş ya da süren bir denetim kalmayınca çıkarılır.
/// Başlangıç diski ve dahili, çıkarılamaz diskler hiç çıkarılmaz.
public enum DiskEject {
    /// Yolun bulunduğu çıkarılabilir birim (başlangıç diski ve dahili diskler için nil).
    public static func volume(of url: URL) -> URL? {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return isEjectable(volume) ? volume : nil
    }

    /// Birim çıkarılabilir mi: kök dosya sistemi değil ve çıkarılabilir, sökülebilir ya da harici.
    public static func isEjectable(_ volume: URL) -> Bool {
        guard RsyncCommand.absolutePath(volume) != "/",
              let values = try? volume.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeIsEjectableKey,
                                                                .volumeIsRemovableKey, .volumeIsInternalKey]),
              values.volumeIsRootFileSystem != true
        else { return false }
        return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
    }

    /// Aynı diskteki (aynı bütün diske bağlı) bağlı birimler, birimin kendisi dahil.
    public static func siblingVolumes(of volume: URL) -> [URL] {
        guard let session = DASessionCreate(kCFAllocatorDefault), let whole = wholeDisk(of: volume, session: session) else { return [volume] }
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let siblings = mounted.filter { wholeDisk(of: $0, session: session) == whole }
        return siblings.isEmpty ? [volume] : siblings
    }

    private static func wholeDisk(of volume: URL, session: DASession) -> String? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) else { return nil }
        return String(cString: name)
    }

    /// Birimlerden biri hâlâ kullanılıyor mu: o birimlerde sırada bekleyen, çalışan ya da karar bekleyen bir iş ya da
    /// süren bir denetim (yollar) var. Kullanıcının duraklattığı, biten ve hata veren işler diski tutmaz.
    public static func isBusy(_ volumes: [URL], jobs: [TransferJob], checking paths: [String] = []) -> Bool {
        let busyJobs = jobs.contains { job in
            (job.status == .waiting || job.status.isActive || job.isAwaitingDecision) && volumes.contains { job.uses(volume: $0) }
        }
        return busyJobs || paths.contains { path in volumes.contains { TransferJob.path(URL(fileURLWithPath: path), isOn: $0) } }
    }

    /// Birimi ve aynı diskteki öteki birimleri ayırıp diski çıkarır (Finder'ın "Çıkar" komutu gibi; kullanıcı arayüzü
    /// göstermeden). Tamamlanınca hata iletisiyle (başarıda nil) çağrılır.
    public static func eject(_ volume: URL, completion: @escaping @Sendable (String?) -> Void) {
        FileManager.default.unmountVolume(at: volume, options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
            completion(error?.localizedDescription)
        }
    }
}
