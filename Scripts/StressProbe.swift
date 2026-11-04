// SPDX-License-Identifier: GPL-3.0-only
// Scripts/stress-test.sh için yardımcı: Copiator'ı erişilebilirlik (AX) arayüzüyle yoklar ve sürer.
// Klavye kullanmaz, odaktaki uygulamaya bağlı değildir. Yalnızca stres testi içindir; uygulamaya girmez.
//
// Alt komutlar:
//   windows                         Copiator'ın erişilebilirlikte görünen pencere sayısı
//   wait <kimlik> present|absent <sn>   Öğe görünene ya da kaybolana kadar bekler (süre dolarsa çıkış 1)
//   press <kimlik>                  Kimliği verilen öğeye basar (AXPress)
//   text <kimlik>                   Öğenin içindeki ilk metin
//   alert                           Açık bir uyarı/sayfa varsa metinleri (yoksa boş)
//   menu <menü|*> <öğe>             Menü öğesine basar ("*": tüm menülerde arar; Dosya menüsünün adı sistem dilindedir)
//   pressname <ad>                  Adı (başlık ya da açıklama) verilen ilk düğmeye basar; sayfalar önce taranır
//   close <pencere başlığı>         Başlığı bununla başlayan pencereyi kapatır
//   buttons                         Görünen düğmelerin adlarını listeler
//   latency <sn>                    Ana iş parçacığının yanıt süresini 100 ms'de bir ölçer; her yeni en kötü değeri yazar
//   audit <ekran>                   VoiceOver'ın adsız okuyacağı denetimleri listeler (çıkış 1: sorun var)
//   mkfiles <klasör> <klasör sayısı> <klasör başına dosya>   Hızlıca çok sayıda küçük dosya oluşturur
import AppKit
import ApplicationServices

let bundleID = "com.babadogantech.copiator"
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func attr(_ e: AXUIElement, _ n: String) -> Any? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ v: Any?) -> String { (v as? String) ?? (v as? NSAttributedString)?.string ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func appElement() -> AXUIElement {
    guard AXIsProcessTrusted() else {
        fail("Erişilebilirlik izni yok: Sistem Ayarları › Gizlilik ve Güvenlik › Aygıt Denetimi ve Veri Erişimi (Erişilebilirlik) listesinde bu betiği çalıştıran uygulamayı açın.")
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { fail("Copiator çalışmıyor") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 30)
    return root
}

/// Pencere listesi yeni açılışta boş dönebiliyor; uygulamanın çocukları da taranır.
func windows(_ root: AXUIElement) -> [AXUIElement] {
    let listed = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return listed.isEmpty ? kids(root).filter { str(attr($0, kAXRoleAttribute)) == "AXWindow" } : listed
}

/// Uzun listeler (anlık görüntü ve karar sayfalarındaki on binlerce satır) taranmaz; iş listesi kısadır ve düğmeleri
/// (ör. `copiator.job.toggle`) onun satırlarındadır, o yüzden taranır.
let skipped: Set<String> = ["AXOutline", "AXTable", "AXRow", "AXMenuBar"]
let scannedLists: Set<String> = ["copiator.joblist"]

func find(_ identifier: String, in root: AXUIElement) -> AXUIElement? {
    var insideJobList = false
    func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        guard depth < 20 else { return nil }
        if str(attr(e, kAXIdentifierAttribute)) == identifier { return e }
        if skipped.contains(str(attr(e, kAXRoleAttribute))), !scannedLists.contains(str(attr(e, kAXIdentifierAttribute))) {
            // İş listesinin satırları ve hücreleri de taranır.
            if !(str(attr(e, kAXRoleAttribute)) == "AXRow" && insideJobList) { return nil }
        }
        let entering = scannedLists.contains(str(attr(e, kAXIdentifierAttribute)))
        if entering { insideJobList = true }
        defer { if entering { insideJobList = false } }
        for c in kids(e) { if let found = walk(c, depth + 1) { return found } }
        return nil
    }
    for w in windows(root) { if let found = walk(w, 0) { return found } }
    return nil
}

func firstText(_ e: AXUIElement) -> String {
    if str(attr(e, kAXRoleAttribute)) == "AXStaticText" { return str(attr(e, kAXValueAttribute)) }
    for c in kids(e) { let t = firstText(c); if !t.isEmpty { return t } }
    return ""
}

switch args.first {
case "windows":
    print(windows(appElement()).count)

case "wait":
    guard args.count == 4, let timeout = Double(args[3]) else { fail("wait <kimlik> present|absent <sn>") }
    let root = appElement()
    let wantPresent = args[2] == "present"
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if (find(args[1], in: root) != nil) == wantPresent {
            print(String(format: "%.2f", Date().timeIntervalSince(start)))
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("zaman aşımı")
    exit(1)

case "press":
    guard args.count == 2 else { fail("press <kimlik>") }
    guard let element = find(args[1], in: appElement()) else { fail("öğe yok: \(args[1])") }
    exit(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? 0 : 1)

case "text":
    guard args.count == 2 else { fail("text <kimlik>") }
    print(find(args[1], in: appElement()).map(firstText) ?? "")

case "alert":
    let root = appElement()
    var texts: [String] = []
    func collect(_ e: AXUIElement) {
        if str(attr(e, kAXRoleAttribute)) == "AXStaticText" { texts.append(str(attr(e, kAXValueAttribute))) }
        kids(e).forEach(collect)
    }
    for w in windows(root) {
        for sheet in kids(w) where str(attr(sheet, kAXRoleAttribute)) == "AXSheet" {
            collect(sheet)
        }
        if str(attr(w, kAXSubroleAttribute)) == "AXDialog" { collect(w) }
    }
    print(texts.filter { !$0.isEmpty }.joined(separator: " — "))

case "pressname", "buttons":
    let root = appElement()
    var found: [(AXUIElement, String)] = []
    func collect(_ e: AXUIElement, _ depth: Int) {
        guard depth < 20 else { return }
        let role = str(attr(e, kAXRoleAttribute))
        if ["AXOutline", "AXTable", "AXMenuBar"].contains(role) { return }
        if ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role) {
            let name = [str(attr(e, kAXTitleAttribute)), str(attr(e, kAXDescriptionAttribute))].first { !$0.isEmpty } ?? ""
            if !name.isEmpty { found.append((e, name)) }
        }
        for c in kids(e) { collect(c, depth + 1) }
    }
    for w in windows(root) {
        // Önce sayfalar: aynı ad (ör. "Vazgeç") pencerede de olabilir.
        for sheet in kids(w) where str(attr(sheet, kAXRoleAttribute)) == "AXSheet" { collect(sheet, 0) }
        collect(w, 0)
    }
    if args.first == "buttons" { print(found.map(\.1).joined(separator: " | ")); exit(0) }
    guard args.count == 2, let target = found.first(where: { $0.1 == args[1] }) else { fail("düğme yok: \(args.dropFirst().first ?? "")") }
    exit(AXUIElementPerformAction(target.0, kAXPressAction as CFString) == .success ? 0 : 1)

case "close":
    guard args.count == 2 else { fail("close <pencere başlığı>") }
    let root = appElement()
    guard let window = windows(root).first(where: { str(attr($0, kAXTitleAttribute)).hasPrefix(args[1]) }),
          let button = attr(window, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) else { fail("pencere yok: \(args[1])") }
    exit(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? 0 : 1)

case "menu":
    guard args.count == 3 else { fail("menu <menü> <öğe>") }
    let root = appElement()
    guard let bar = attr(root, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { fail("menü çubuğu yok") }
    let tops = kids(bar).filter { args[1] == "*" || str(attr($0, kAXTitleAttribute)) == args[1] }
    guard let item = tops.lazy.compactMap({ top in
        kids(top).first.flatMap { menu in kids(menu).first(where: { str(attr($0, kAXTitleAttribute)) == args[2] }) }
    }).first else { fail("menü öğesi yok: \(args[1]) › \(args[2])") }
    guard (attr(item, kAXEnabledAttribute) as? Bool) != false else { fail("menü öğesi pasif: \(args[2])") }
    exit(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? 0 : 1)

case "latency":
    let duration = Double(args.dropFirst().first ?? "10") ?? 10
    let root = appElement()
    let start = Date()
    var worst = 0.0
    while Date().timeIntervalSince(start) < duration {
        let t0 = Date()
        var v: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &v)
        let ms = Date().timeIntervalSince(t0) * 1000
        // Her yeni en kötü değer yazılır: betik ölçümü durdurduğunda (kill) son satır sonuçtur.
        if ms > worst { worst = ms; print(Int(worst)); fflush(stdout) }
        Thread.sleep(forTimeInterval: 0.1)
    }

case "audit":
    let screen = args.dropFirst().first ?? "?"
    let root = appElement()
    let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
                                   "AXSecureTextField", "AXSlider", "AXLink", "AXComboBox", "AXIncrementor", "AXDisclosureTriangle"]
    let systemSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"]
    func name(_ e: AXUIElement) -> String {
        // Metin alanlarında VoiceOver yer tutucuyu (placeholder) okur.
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXAttributedDescription", kAXPlaceholderValueAttribute] {
            let s = str(attr(e, key)); if !s.isEmpty { return s }
        }
        for c in kids(e) where str(attr(c, kAXRoleAttribute)) == "AXStaticText" {
            let s = str(attr(c, kAXValueAttribute)); if !s.isEmpty { return s }
        }
        if let titleUI = attr(e, kAXTitleUIElementAttribute) { return str(attr(titleUI as! AXUIElement, kAXValueAttribute)) }
        return ""
    }
    var checked = 0
    var problems: [String] = []
    func walk(_ e: AXUIElement, _ depth: Int, window: String) {
        guard depth < 25 else { return }
        let role = str(attr(e, kAXRoleAttribute))
        if ["AXOutline", "AXTable", "AXMenuBar", "AXScrollBar"].contains(role) { return }
        var size = CGSize.zero
        if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        let visible = size.width >= 2 && size.height >= 2
        if interactive.contains(role), !systemSubroles.contains(str(attr(e, kAXSubroleAttribute))), visible {
            checked += 1
            if name(e).isEmpty {
                var position = CGPoint.zero
                if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &position) }
                problems.append("  ✘ [\(window)] \(role) \(Int(size.width))x\(Int(size.height)) @\(Int(position.x)),\(Int(position.y)) yardım=\"\(str(attr(e, kAXHelpAttribute)))\"")
            }
        }
        for c in kids(e) { walk(c, depth + 1, window: window) }
    }
    let all = windows(root)
    for w in all { walk(w, 0, window: String(str(attr(w, kAXTitleAttribute)).prefix(30))) }
    print("\(screen): \(all.count) pencere, \(checked) denetim, \(problems.count) adsız")
    problems.forEach { print($0) }
    exit(problems.isEmpty ? 0 : 1)

case "mkfiles":
    guard args.count == 4, let folders = Int(args[2]), let perFolder = Int(args[3]) else { fail("mkfiles <klasör> <klasör sayısı> <dosya>") }
    let base = URL(fileURLWithPath: args[1])
    for d in 0..<folders {
        let folder = base.appendingPathComponent(String(format: "klasör%03d", d))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in 0..<perFolder {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(String(format: "dosya%04d.txt", f)).path, contents: Data("\(d)-\(f)\n".utf8))
        }
    }
    print(folders * perFolder)

default:
    fail("Kullanım: StressProbe windows | wait | press | text | menu | latency | audit | mkfiles (ayrıntı: dosyanın başı)")
}
