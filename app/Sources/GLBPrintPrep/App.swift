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
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files or Folders…") { store.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("GLB Print Prep on GitHub") { openURL(ProjectLinks.repository) }
                Button("Report an Issue…") { openURL(ProjectLinks.issues) }
                Button("Check for Updates…") { openURL(ProjectLinks.releases) }
                Divider()
                Button("Support GLB Print Prep (GitHub Sponsors)…") { openURL(ProjectLinks.githubSponsors) }
                if let koFi = ProjectLinks.koFi {
                    Button("Buy Me a Coffee (Ko-fi)…") { openURL(koFi) }
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
