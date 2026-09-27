import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        // Row and toggle labels use sentence case, like macOS System Settings; section headers are titles.
        Form {
            Section {
                Picker("Nozzle", selection: $store.nozzleMM) {
                    ForEach(PrintDefaults.nozzleSizes, id: \.self) { Text("\($0.formatted()) mm").tag($0) }
                }
                Picker("Layer height", selection: $store.layerMM) {
                    ForEach(PrintDefaults.layerHeights, id: \.self) { Text("\($0.formatted()) mm").tag($0) }
                }
            } header: {
                Text("Printer")
            }
            Section {
                // Short menu items; the resulting tolerance is shown once, as the row's subtitle.
                Picker(selection: $store.detailLevel) {
                    ForEach(DetailLevel.allCases) { Text($0.name).tag($0) }
                } label: {
                    Text("Detail level")
                    Text("Tolerance \(store.toleranceMM.formatted()) mm")
                }
                .help(
                    "Maximum surface deviation. High is the smaller of ¼ layer height and ⅒ nozzle; "
                        + "each step down doubles it."
                )
                Picker("Default base", selection: $store.baseMM) {
                    ForEach(PrintDefaults.baseSizes, id: \.self) { Text("Ø \($0.formatted()) mm").tag($0) }
                }
                Toggle(isOn: $store.offerReduction) {
                    Text("Offer optimization for heavy models")
                    Text("Models above 1 million triangles.")
                }
                Toggle("Optimize automatically after repair", isOn: $store.autoReduce)
                Toggle(isOn: $store.trashUnoptimized) {
                    Text("Keep only optimized versions")
                    Text("After an optimization within tolerance, move the non-optimized file to the Trash.")
                }
            } header: {
                Text("3D Print Optimization")
            } footer: {
                Text(
                    "The model's round base gives its real size. Optimization keeps the fewest triangles "
                        + "whose measured deviation (Hausdorff distance) stays within the tolerance. "
                        + "It never exceeds 1 million triangles, never worsens topology and always writes a new file."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $store.trashOriginals) {
                    Text("Move originals to the Trash")
                    Text("Only after every test passes. You can put them back from the Trash.")
                }
            } header: {
                Text("Repair")
            }
            Section {
                Toggle(isOn: $store.alwaysSpinThumbnails) {
                    Text("Rotate thumbnails continuously")
                    Text(
                        "When off, a thumbnail rotates only while the pointer is over it. "
                            + "Continuous rotation uses more power.")
                }
            } header: {
                Text("Previews")
            }
            Section {
                supportLink("Sponsor on GitHub", systemImage: "heart", url: ProjectLinks.githubSponsors)
                if let koFi = ProjectLinks.koFi {
                    supportLink("Buy me a coffee on Ko-fi", systemImage: "cup.and.saucer", url: koFi)
                }
                supportLink(
                    "Source code and issues", systemImage: "chevron.left.forwardslash.chevron.right",
                    url: ProjectLinks.repository)
            } header: {
                Text("Support the Project")
            } footer: {
                Text("GLB Print Prep is free and open source. If it saves you time, a small donation helps.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Fixed width; the height follows the content up to a cap, beyond which the form scrolls.
        .frame(width: 560)
        .frame(minHeight: 920, idealHeight: 920, maxHeight: 1000)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Full-width row that opens a web page: icon and title on the left, external-link arrow on the right.
    private func supportLink(_ title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .accessibilityHint("Opens \(url.host() ?? "the web page") in your browser")
    }
}
