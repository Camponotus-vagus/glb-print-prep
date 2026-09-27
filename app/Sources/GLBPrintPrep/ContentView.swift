import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// Liquid Glass guidelines (HIG "Materials" + "Adopting Liquid Glass"):
//  • glass lives ONLY in the functional layer (toolbar, floating status bar, controls over the
//    3D viewer), never in the content layer (the file list);
//  • system components wherever possible (toolbar, inspector, ContentUnavailableView);
//  • custom effects grouped in a GlassEffectContainer, morphing via glassEffectID;
//  • no glass on glass; tint used sparingly and only with system colours;
//  • Reduce Motion / Reduce Transparency respected (system glass adapts by itself).

// MARK: - Main window

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var dropTargeted = false
    @State private var showLog = false

    var body: some View {
        @Bindable var store = store
        Group {
            if store.jobs.isEmpty {
                EmptyState(targeted: dropTargeted) { store.showImporter = true }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.jobs) { JobCard(job: $0) }
                        DropStrip { store.showImporter = true }
                    }
                    .padding(20)
                }
                // On macOS the .hard style is recommended when text scrolls under a bar:
                // a more opaque, crisp edge keeps the status bar metrics legible.
                .scrollEdgeEffectStyle(.hard, for: .bottom)
                // Drop highlight on the file list only (not over the toolbar, status bar or log).
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.tint, style: .init(lineWidth: 3, dash: [10, 6]))
                            .background(.tint.opacity(0.05), in: .rect(cornerRadius: 18))
                            .padding(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: dropTargeted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("GLB Print Prep")
        // Global status bar: functional layer floating above the list.
        // safeAreaBar registers the bar for the scroll edge effect (legibility over scrolling content)
        // and insets the scroll content, so the last card and the drop strip can scroll above it.
        .safeAreaBar(edge: .bottom) {
            if !store.jobs.isEmpty {
                StatusBar().padding(.horizontal, 20).padding(.bottom, 14)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls); return true
        } isTargeted: {
            dropTargeted = $0
        }
        // The inspector is animated by the system split view. No withAnimation around the toggle:
        // an extra SwiftUI animation transaction made every card re-layout animate too (see LogPanel).
        .inspector(isPresented: $showLog) {
            LogPanel().inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .fileImporter(
            isPresented: $store.showImporter, allowedContentTypes: [.glb, .folder], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
        .toolbar {
            // Groups separated by function (ToolbarSpacer .fixed), icons only + accessibility labels
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.showImporter = true
                } label: {
                    Label("Add Files or Folders", systemImage: "plus")
                }
                .help("Add .glb files or whole folders, subfolders included (⌘O)")
                .accessibilityIdentifier("toolbar.add")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $store.trashOriginals) {
                    // The slashed symbol makes the Off state readable even without the on-state tint.
                    Label(
                        "Move Originals to Trash After Tests",
                        systemImage: store.trashOriginals ? "trash" : "trash.slash")
                }
                .toggleStyle(.button)
                .contentTransition(.symbolEffect(.replace))
                .help(
                    store.trashOriginals
                        ? "On: once every test passes, the original goes to the Trash (restorable)"
                        : "Off: originals are always kept"
                )
                .accessibilityIdentifier("toolbar.trashOriginals")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLog.toggle()
                } label: {
                    Label(showLog ? "Hide Log" : "Show Log", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showLog ? "Hide the detailed log (⌥⌘I)" : "Show the detailed log (⌥⌘I)")
                .accessibilityIdentifier("toolbar.log")
            }
        }
        .alert("Setup Required", isPresented: .constant(store.setupError != nil)) {
            Button("OK") { store.setupError = nil }
        } message: {
            Text(store.setupError ?? "")
        }
    }
}

// MARK: - Empty state and drop zone (content layer: no glass)

/// A self-sized drop zone: the dashed border is the background of the padded content itself,
/// so icon, title, description and button always sit inside it (ContentUnavailableView reported
/// a size smaller than its actions, which then spilled over the border).
struct EmptyState: View {
    var targeted: Bool
    var choose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: targeted)
                .accessibilityHidden(true)
                .padding(.bottom, 16)
            Text("Drop .glb Files or Folders Here")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text(
                "Decompresses meshopt, quantization and Draco, verifies the result with "
                    + "5 tests, and only then moves the original to the Trash. Heavy models can "
                    + "then be optimized for 3D printing within a measured tolerance."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .frame(maxWidth: 400)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 24)
            Button("Choose Files or Folders…", action: choose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("empty.choose")
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(targeted ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(Color.clear))
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(
                    targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    style: .init(lineWidth: targeted ? 3 : 2, dash: [12, 8])
                )
        }
        .accessibilityElement(children: .contain)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: targeted)
    }
}

struct DropStrip: View {
    var choose: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle").accessibilityHidden(true)
            Text("Drop more files or folders here, or")
            Button("choose…", action: choose)
                .buttonStyle(.link)
                .accessibilityLabel("Choose Files or Folders")
                .accessibilityIdentifier("drop.choose")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, style: .init(lineWidth: 1.5, dash: [8, 6])))
    }
}

// MARK: - Log (system inspector)

/// Cheap to open and to update: a LazyVStack builds only the visible rows (the previous List
/// re-diffed `Array(enumerated())` of up to 2000 strings on every append), ids are plain indices,
/// and the view follows the tail only while the user is at the bottom.
struct LogPanel: View {
    @Environment(Store.self) private var store
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var followsTail = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(store.log.indices, id: \.self) { i in
                    LogRow(line: store.log[i])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .scrollPosition($position)
        // Short logs sit at the top; the initial position and growth follow the tail.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Re-evaluated only when a user scroll ends, so appends can't race with it.
        .onScrollPhaseChange { _, phase, context in
            guard phase == .idle else { return }
            let g = context.geometry
            followsTail = g.visibleRect.maxY >= g.contentSize.height - 24
        }
        .onChange(of: store.log.count) {
            if followsTail { position.scrollTo(edge: .bottom) }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .overlay {
            if store.log.isEmpty {
                Text("No messages yet").font(.callout).foregroundStyle(.tertiary)
            }
        }
        // header as a bar registered for the scroll edge effect (no custom background)
        .safeAreaBar(edge: .top) {
            HStack(alignment: .firstTextBaseline) {
                Text("Log").font(.headline)
                Spacer()
                if !store.log.isEmpty {
                    Text("\(store.log.count) lines").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        }
    }
}

/// One log line: the timestamp ("8:41:44  message") in a quiet fixed column, the message in a
/// proportional font that wraps long file paths far better than the old monospaced caption.
private struct LogRow: View {
    let line: String

    var body: some View {
        let parts = Self.split(line)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(parts.time)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 46, alignment: .trailing)
                .fixedSize()
            Text(parts.message)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private static func split(_ line: String) -> (time: String, message: String) {
        guard let r = line.range(of: "  ") else { return ("", line) }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }
}
