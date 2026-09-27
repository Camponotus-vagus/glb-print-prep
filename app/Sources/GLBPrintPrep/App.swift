import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Binary glTF (.glb). Also declared in Info.plist as an imported type.
    static let glb = UTType(importedAs: "org.khronos.glb", conformingTo: .data)
}

@main
struct GLBPrintPrepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openURL) private var openURL
    @State private var store = Store.shared

    init() {
        SpinComponent.registerComponent()
        SpinSystem.registerSystem()
    }

    var body: some SwiftUI.Scene {
        Window("GLB Print Prep", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 820)  // room for a few result cards on first launch
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files or Folders…") { store.showImporter = true }
                    .keyboardShortcut("o")
            }
            // These only open web pages, so no ellipses (HIG: "…" means more input is needed).
            CommandGroup(replacing: .help) {
                Button("GLB Print Prep on GitHub") { openURL(ProjectLinks.repository) }
                Button("Latest Releases on GitHub") { openURL(ProjectLinks.releases) }
                Divider()
                Button("Report an Issue") { openURL(ProjectLinks.issues) }
                Divider()
                Button("Sponsor GLB Print Prep on GitHub") { openURL(ProjectLinks.githubSponsors) }
                if let koFi = ProjectLinks.koFi {
                    Button("Buy Me a Coffee on Ko-fi") { openURL(koFi) }
                }
            }
        }

        Settings {
            SettingsView().environment(store)
        }

        WindowGroup("Preview", id: "viewer", for: ViewerTarget.self) { $target in
            if let target {
                ModelViewerWindow(target: target)
                    .frame(minWidth: 640, minHeight: 520)
            }
        }
        .defaultSize(width: 900, height: 720)
        .restorationBehavior(.disabled)  // don't reopen previews of files that may no longer exist
    }
}

/// Receives files dropped on the Dock icon / Finder or opened with "Open With".
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Testing hook: `-GPPForceAppearance dark|light` (launch argument) forces the appearance; no-op when absent.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let forced = UserDefaults.standard.string(forKey: "GPPForceAppearance")
        MainActor.assumeIsolated {
            switch forced {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Store.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.cancelAll() }
    }
}

struct ViewerTarget: Codable, Hashable {
    var url: URL
    var title: String
}
