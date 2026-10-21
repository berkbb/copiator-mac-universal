// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

@main
struct CopiatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var model = AppModel.shared

    var body: some Scene {
        let _ = settings.customShortcuts
        Window(settings.t(.appName), id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.launch() }
        }
        .defaultSize(width: 1080, height: 680)
        .commands { AppCommands(model: model, settings: settings) }

        Window(settings.t(.menuAbout), id: WindowID.about) {
            AboutView()
                .environment(model)
                .environment(settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
        }

        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            MenuBarContent()
                .environment(model)
                .environment(settings)
        } label: {
            MenuBarLabel(isRunning: model.runningJobID != nil, title: settings.t(.appName))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = FinderServices()
    private let volumes = VolumeWatcher()
    private let dock = DockProgress()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Uygulama çökerse ya da sonlandırılırsa rsync yetim kalmasın (bkz. ChildProcessGuard).
        ChildProcessGuard.installCrashHandlers()
        // Finder sağ tık menüsündeki "Hızlı Eylemler / Servisler" öğesi.
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        let model = AppModel.shared
        // Disk takılınca başlayan işler; çıkarılan diskteki iş duraklar, yeniden takılınca sürer.
        volumes.start(model: model)
        model.onActivityChange = { [dock, weak model] in
            guard let model else { return }
            dock.update(fraction: model.runningFraction, active: model.runningJobID != nil, badge: model.pendingCount,
                        enabled: model.settings.showDockProgress)
        }
        // Pencere açılmadan (Kestirmeler ya da Finder servisiyle) başlatılsa da kuyruk ve motor hazırlanır.
        Task { await model.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Kopyalama sürerken pencere kapatılınca uygulama da kapanıp işi kesmesin; menü çubuğu simgesi açıkken
        // uygulama (disk takılınca başlayan işler için) çalışmayı sürdürür.
        AppModel.shared.runningJobID == nil && !AppSettings.shared.showMenuBarIcon
    }
}

struct AppCommands: Commands {
    let model: AppModel
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Uygulama Finder servisiyle başlatıldığında SwiftUI ana pencereyi açmaz; pencere açma eylemi modele verilir.
        let _ = model.registerWindowOpener { [openWindow] in openWindow(id: WindowID.main) }
        CommandGroup(replacing: .appInfo) {
            Button(settings.t(.menuAbout)) { openWindow(id: WindowID.about) }
            Button(settings.t(.menuCheckEngineUpdates)) {
                Task { await model.checkForUpdates(interactive: true) }
            }
            .disabled(model.operation != nil)
            Button(settings.t(.menuCheckAppUpdates)) {
                Task { await model.checkForAppUpdate(interactive: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            let newJob = settings.shortcut(for: .newJob)
            Button(settings.t(.menuNewJob)) {
                openWindow(id: WindowID.main)
                model.beginNewJob()
            }
            .keyboardShortcut(newJob.keyEquivalent, modifiers: newJob.eventModifiers)
        }

        CommandMenu(settings.t(.menuJob)) {
            let selected = model.selectedJobs
            let resume = settings.shortcut(for: .resume)
            Button(settings.t(.menuResumeJob)) { model.resume(model.selection) }
                .keyboardShortcut(resume.keyEquivalent, modifiers: resume.eventModifiers)
                .disabled(!selected.contains { JobQueue.canResume($0) || JobQueue.canRunAgain($0) })
            let pause = settings.shortcut(for: .pause)
            Button(settings.t(.menuPauseJob)) { model.pause(model.selection) }
                .keyboardShortcut(pause.keyEquivalent, modifiers: pause.eventModifiers)
                .disabled(!selected.contains(where: JobQueue.canPause))
            Divider()
            let resumeAll = settings.shortcut(for: .resumeAll)
            Button(settings.t(.menuResumeAll)) { model.resumeAll() }
                .keyboardShortcut(resumeAll.keyEquivalent, modifiers: resumeAll.eventModifiers)
                .disabled(!model.jobs.contains(where: JobQueue.canResume))
            let pauseAll = settings.shortcut(for: .pauseAll)
            Button(settings.t(.menuPauseAll)) { model.pauseAll() }
                .keyboardShortcut(pauseAll.keyEquivalent, modifiers: pauseAll.eventModifiers)
                .disabled(!model.jobs.contains(where: JobQueue.canPause))
            Button(settings.t(settings.queueHeld ? .toolbarReleaseQueue : .toolbarHoldQueue)) { model.toggleQueueHold() }
            Divider()
            let verify = settings.shortcut(for: .verify)
            Button(settings.t(.menuVerify)) { if let id = selected.first?.id { model.verify(id, checksum: false) } }
                .keyboardShortcut(verify.keyEquivalent, modifiers: verify.eventModifiers)
                .disabled(selected.count != 1 || !selected.allSatisfy(JobQueue.canVerify) || model.operation != nil)
            Button(settings.t(.menuVerifyChecksum)) { if let id = selected.first?.id { model.verify(id, checksum: true) } }
                .disabled(selected.count != 1 || !selected.allSatisfy(JobQueue.canVerify) || model.operation != nil)
            Divider()
            Button(settings.t(.menuEditJob)) { if let id = selected.first?.id { model.beginEdit(id) } }
                .disabled(selected.count != 1 || !selected.allSatisfy(JobQueue.canEdit))
            Button(settings.t(.menuDuplicateJob)) { if let id = selected.first?.id { model.beginDuplicate(id) } }
                .disabled(selected.count != 1)
            Divider()
            Button(settings.t(.menuShowSource)) { if let id = selected.first?.id { model.revealSource(id) } }
                .disabled(selected.count != 1)
            Button(settings.t(.menuShowDestination)) { if let id = selected.first?.id { model.revealDestination(id) } }
                .disabled(selected.count != 1)
            Divider()
            let remove = settings.shortcut(for: .remove)
            Button(settings.t(.menuRemoveJob)) { model.remove(model.selection) }
                .keyboardShortcut(remove.keyEquivalent, modifiers: remove.eventModifiers)
                .disabled(!selected.contains(where: JobQueue.canRemove))
            Button(settings.t(.menuRemoveFinished)) { model.removeFinished() }
                .disabled(!model.jobs.contains { $0.status == .finished })
        }

        CommandGroup(before: .toolbar) {
            let inspector = settings.shortcut(for: .inspector)
            Button(settings.t(.menuInspector)) { model.toggleInspector() }
                .keyboardShortcut(inspector.keyEquivalent, modifiers: inspector.eventModifiers)
                .disabled(model.jobs.isEmpty)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(settings.t(.menuEngineManual)) { NSWorkspace.shared.open(AppLinks.engineManual) }
            Button(settings.t(.menuWebsite)) { NSWorkspace.shared.open(AppLinks.repository) }
        }
    }
}
