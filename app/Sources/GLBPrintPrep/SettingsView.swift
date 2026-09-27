import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Nozzle", selection: $store.nozzleMM) {
                    ForEach(PrintDefaults.nozzleSizes, id: \.self) { Text("\($0.formatted()) mm").tag($0) }
                }
                Picker("Layer Height", selection: $store.layerMM) {
                    ForEach(PrintDefaults.layerHeights, id: \.self) { Text("\($0.formatted()) mm").tag($0) }
                }
            } header: {
                Text("Printer")
            }
            Section {
                Picker("Detail Level", selection: $store.detailLevel) {
                    ForEach(DetailLevel.allCases) { l in
                        Text(
                            "\(l.name) — tolerance \(l.tolerance(layer: store.layerMM, nozzle: store.nozzleMM).formatted()) "
                                + "mm"
                        ).tag(l)
                    }
                }
                Picker("Default Base", selection: $store.baseMM) {
                    ForEach(PrintDefaults.baseSizes, id: \.self) { Text("Ø \($0.formatted()) mm").tag($0) }
                }
                Toggle("Offer optimization for models above 1 million triangles", isOn: $store.offerReduction)
                Toggle("Optimize automatically after repair", isOn: $store.autoReduce)
                Toggle(isOn: $store.trashUnoptimized) {
                    Text("Keep only optimized versions")
                    Text(
                        "After a successful optimization within tolerance, move the non-optimized "
                            + "file to the Trash (restorable)."
                    )
                }
            } header: {
                Text("3D Print Optimization")
            } footer: {
                Text(
                    "The app detects the model's round base and derives its real-world scale. "
                        + "It then searches for the fewest triangles whose measured deviation from "
                        + "the original surface (Hausdorff distance) stays within the tolerance — "
                        + "never above 1 million, never worsening topology. High = ¼ of the layer "
                        + "height and ⅒ of the nozzle. It always writes a new file."
                )
                .foregroundStyle(.secondary)
            }
            Section("Repair") {
                Toggle("Move the original to the Trash once every test passes", isOn: $store.trashOriginals)
            }
            Section {
                Link(destination: ProjectLinks.githubSponsors) {
                    Label("Sponsor on GitHub", systemImage: "heart")
                }
                if let koFi = ProjectLinks.koFi {
                    Link(destination: koFi) { Label("Buy me a coffee on Ko-fi", systemImage: "cup.and.saucer") }
                }
                Link(destination: ProjectLinks.repository) {
                    Label("Source code and issues on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("Support the Project")
            } footer: {
                Text(
                    "GLB Print Prep is free and open source. If it saves you time, a small donation "
                        + "helps keep it maintained."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
