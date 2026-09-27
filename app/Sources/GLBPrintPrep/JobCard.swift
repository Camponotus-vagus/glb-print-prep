import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File card (content layer)

struct JobCard: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let job: FileJob
    @State private var expanded = false
    /// Compact layout when the column is narrow (small window or inspector open). Driven by the card width with
    /// hysteresis so it flips once (and without animation) while the inspector slides in or out.
    @State private var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 12 : 16) {
            thumbnail
                .frame(width: compact ? 96 : 140, height: compact ? 96 : 140)
                .clipShape(ConcentricRectangle())
                .overlay(ConcentricRectangle().stroke(.quaternary, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                if let base = job.kind.baseMM, let tol = job.kind.toleranceMM {
                    Label(
                        "Print optimization · base Ø \(base.formatted()) mm · tolerance \(tol.formatted()) mm",
                        systemImage: "square.stack.3d.down.right"
                    )
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(titleHelp)
                    sizes
                }
                statusRow
                if job.state == .running {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        VStack(alignment: .leading, spacing: 5) {
                            ProgressView(value: job.progress)
                            HStack(spacing: 4) {
                                Text(job.progress, format: .percent.precision(.fractionLength(0)))
                                Text("· elapsed \(fmt(job.elapsed))")
                                if let eta = job.eta { Text("· ~\(fmt(eta)) remaining") }
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HeartbeatRow(job: job, now: ctx.date)
                        }
                        .lineLimit(1)
                    }
                }
                if job.state == .ok, let s = job.stats {
                    Text(statsText(s)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if job.state == .ok && !job.kind.isOptimize { trashLine }
                if job.state == .ok && job.kind.isOptimize && job.trashedURL != nil {
                    HStack(spacing: 8) {
                        Label("Non-optimized version moved to the Trash", systemImage: "trash").font(.callout)
                            .foregroundStyle(.secondary)
                        restoreButton
                    }
                }
                if job.outSuperseded {
                    Label(
                        "Repaired file replaced by the optimized version (in the Trash)",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if store.canOfferReduction(job) { ReductionOffer(job: job) }
                if !job.steps.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        details
                    } label: {
                        Text(job.tests.isEmpty ? "Details" : "Details · \(job.tests.count) tests passed").font(.callout)
                    }
                    .accessibilityIdentifier("card.details")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(14)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            // enter compact below 560 pt, leave above 600 pt: no flip-flopping around a single threshold.
            // Low enough that the default window with the Log open keeps the regular layout (no snap).
            let next = compact ? width < 600 : width < 560
            guard next != compact else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { compact = next }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .containerShape(.rect(cornerRadius: 22))  // → thumbnail concentric with the card
        .animation(.snappy, value: job.state)
    }

    // MARK: Title and sizes

    /// A finished job is named after the file it produced (the one the buttons act on); the input is shown
    /// on the size line as "from …".
    private var producedName: String? {
        guard job.state == .ok, let out = job.outURL, out.lastPathComponent != job.name else { return nil }
        return out.lastPathComponent
    }

    private var title: String { producedName ?? job.name }

    private var titleHelp: String {
        producedName.map { "\($0)\nfrom \(job.name)" } ?? job.name
    }

    private var sizes: some View {
        HStack(spacing: 6) {
            Group {
                Text(job.size, format: .byteCount(style: .file))
                if let s = job.stats, s.outSize > 0 {
                    Image(systemName: "arrow.right").font(.caption).accessibilityLabel("to")
                    Text(Int64(s.outSize), format: .byteCount(style: .file))
                }
            }
            .fixedSize()
            if producedName != nil {
                Text("· from \(job.name)").lineLimit(1).truncationMode(.middle)
                    .help(job.name)
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Status

    /// Status line, followed by the compression extensions of the input when there is room for them.
    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusLine
                if !compact && !job.extensions.isEmpty { extensionChips }
            }
            statusLine
        }
    }

    private var extensionChips: some View {
        HStack(spacing: 4) {
            ForEach(job.extensions, id: \.self) { ext in
                Text(ext.replacingOccurrences(of: "EXT_", with: "").replacingOccurrences(of: "KHR_", with: ""))
                    .font(.caption2.weight(.medium)).foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.fill.tertiary, in: .capsule)
                    .help("Compression extension of the original file: \(ext)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compression: \(job.extensions.joined(separator: ", "))")
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .running:
                ProgressView().controlSize(.small)
                Text(job.stepLabel).lineLimit(1)
                if let s = job.stepStartedAt {
                    Text(s, style: .timer).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(job.stepLabel)
            case .failed(let m):
                // same glyph family as the thumbnail; engine messages start lowercase
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(m.prefix(1).uppercased() + String(m.dropFirst())).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .skipped:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(job.stepLabel)
            case .cancelled:
                Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
                Text(job.stepLabel)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Queued")
            }
        }
        .font(.callout)
    }

    // MARK: Thumbnail

    @ViewBuilder private var thumbnail: some View {
        if job.state == .ok, let url = job.previewURL ?? job.outURL {
            ModelThumbnail(url: url)
                .contentShape(.rect)
                .onTapGesture { openViewer() }
                .help("Click to open the full 3D preview")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Preview of \(title)")
                .accessibilityAction { openViewer() }
        } else {
            // One progress indicator is enough: the status line and the bar below already show it.
            ZStack {
                Rectangle().fill(.quinary)
                Image(systemName: icon)
                    .font(.system(size: compact ? 30 : 38))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: job.kind.isOptimize ? "square.stack.3d.down.right" : "clock"
        case .running: job.kind.isOptimize ? "square.stack.3d.down.right" : "cube.transparent"
        case .skipped: "checkmark.seal"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        default: "cube"
        }
    }
    private var iconColor: Color {
        switch job.state {
        case .failed: .red
        case .skipped: .green
        default: .secondary
        }
    }

    // MARK: Results

    /// "a · b · c", breaking lines only between items (never inside "in 0:01" or "286.824 triangles").
    private func statsText(_ s: EngineEvent.Stats) -> String {
        var parts: [String] = []
        if job.kind.isOptimize, let before = s.trisBefore {
            let saved = 1 - Double(s.tris) / Double(max(before, 1))
            let pct = saved.formatted(.percent.precision(.fractionLength(0)))
            parts.append("\(before.formatted()) → \(s.tris.formatted()) triangles (−\(pct))")
            let base = (s.baseDetected ?? false) ? "base detected" : "base estimated from footprint"
            if let h = s.heightMM {
                parts.append("miniature \(mm(h, digits: 1)) tall (\(base))")
            } else {
                parts.append(base)
            }
            parts.append("max deviation \(mm(s.devMaxMM ?? 0, digits: 3))")
            parts.append("\((0.99).formatted(.percent)) ≤ \(mm(s.devP99MM ?? 0, digits: 3))")
            parts.append("mean \(mm(s.devMeanMM ?? 0, digits: 4))")
        } else {
            // a point cloud's vertices are its points: don't say it twice
            if s.tris > 0 || s.points == 0 { parts.append("\(s.verts.formatted()) vertices") }
            if s.tris > 0 { parts.append("\(s.tris.formatted()) triangles") }
            if s.points > 0 { parts.append("\(s.points.formatted()) points") }
            if s.textures > 0 { parts.append("\(s.textures) texture\(s.textures == 1 ? "" : "s")") }
        }
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }

    /// Locale-aware millimetres (decimal comma on an Italian Mac, like every other number in the card).
    private func mm(_ x: Double, digits: Int) -> String {
        "\(x.formatted(.number.precision(.fractionLength(digits)))) mm"
    }

    private var restoreButton: some View {
        Button("Restore") { store.restoreOriginal(job) }
            .buttonStyle(.link)
            .accessibilityIdentifier("card.restore")
    }

    @ViewBuilder private var trashLine: some View {
        if job.trashedURL != nil {
            HStack(spacing: 8) {
                Label("Original moved to the Trash", systemImage: "trash").font(.callout).foregroundStyle(.secondary)
                restoreButton
            }
        } else if job.restored {
            Label("Original restored", systemImage: "arrow.uturn.backward").font(.callout).foregroundStyle(.secondary)
        } else if let e = job.trashError {
            Label("Original not moved to the Trash: \(e)", systemImage: "exclamationmark.triangle").font(.callout)
                .foregroundStyle(.orange)
        } else {
            Label("Original kept", systemImage: "doc").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(job.steps) { s in
                    GridRow {
                        stepSymbol(s)
                        Text(s.label)
                        Text(stepTime(s)).monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
            if !job.tests.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tests passed").font(.callout.weight(.semibold))
                    ForEach(job.tests) { t in
                        Label(t.label, systemImage: "checkmark.seal.fill").font(.callout)
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var isFailed: Bool { if case .failed = job.state { true } else { false } }

    /// Unfinished steps: in progress while running, the failing step (red) after a failure, "–" otherwise.
    private func stepSymbol(_ s: StepRecord) -> some View {
        let name: String
        let style: AnyShapeStyle
        if s.ms != nil {
            name = "checkmark"
            style = AnyShapeStyle(.green)
        } else if job.state == .running {
            name = "circle.dotted"
            style = AnyShapeStyle(.secondary)
        } else if isFailed {
            name = "xmark"
            style = AnyShapeStyle(.red)
        } else {
            name = "minus"
            style = AnyShapeStyle(.secondary)
        }
        return Image(systemName: name).foregroundStyle(style)
    }

    private func stepTime(_ s: StepRecord) -> String {
        if let ms = s.ms { return "\(ms.formatted()) ms" }
        if job.state == .running { return "…" }
        return isFailed ? "failed" : "–"
    }

    // MARK: Actions (standard controls in the content layer, no custom glass)

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if job.state == .ok && !job.outSuperseded {
                actionButton("3D Preview", icon: "cube", id: "card.preview", tip: "Open the model in the 3D viewer") {
                    openViewer()
                }
                if let out = job.outURL {
                    actionButton(
                        "Show in Finder", icon: "folder", id: "card.reveal",
                        tip: "Show \(out.lastPathComponent) in Finder"
                    ) {
                        store.revealInFinder(out)
                    }
                }
            }
            if job.state == .running || job.state == .queued {
                actionButton(
                    "Cancel", icon: "xmark", id: "card.cancel", role: .destructive,
                    tip: "Stop processing this file (the original is not touched)"
                ) {
                    store.cancel(job)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()  // column as wide as its widest button; the others stretch to match
    }

    private func actionButton(
        _ title: LocalizedStringKey, icon: String, id: String, role: ButtonRole? = nil, tip: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .labelStyle(AdaptiveLabelStyle(compact: compact))
                .frame(maxWidth: .infinity)
        }
        .help(tip)
        .accessibilityLabel(title)  // the icon-only style would otherwise leave VoiceOver with just "button"
        .accessibilityIdentifier(id)
    }

    private func openViewer() {
        guard let out = job.outURL else { return }
        openWindow(id: "viewer", value: ViewerTarget(url: out, title: out.lastPathComponent))
    }
}

/// Icon only in narrow columns. Buttons using it must set `.accessibilityLabel` themselves: the re-wrapped
/// label does not reliably expose its title to accessibility.
struct AdaptiveLabelStyle: LabelStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Optimization offer (content layer: standard controls)

struct ReductionOffer: View {
    @Environment(Store.self) private var store
    let job: FileJob

    var body: some View {
        let red = store.reduction(of: job)
        Group {
            switch red?.state {
            case .ok?:
                row {
                    Label {
                        Text("Print-ready version: \((red?.stats?.tris ?? 0).formatted()) triangles")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } control: {
                    Menu("Another Base") { baseButtons }
                        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                        .accessibilityIdentifier("card.optimize")
                }
            case .running?, .queued?:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Optimizing for print…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                row {
                    Label {
                        Text(
                            "\((job.triangles ?? 0).formatted()) triangles: "
                                + "slicers like Bambu Studio recommend simplifying"
                        )
                        .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "printer").foregroundStyle(.tint)
                    }
                } control: {
                    optimizeMenu
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .animation(.snappy, value: red?.state)
    }

    /// Message and control side by side when the message fits on one line, otherwise stacked
    /// (instead of squeezing the message into a word-per-line column next to the control).
    private func row<M: View, C: View>(
        @ViewBuilder message: () -> M, @ViewBuilder control: () -> C
    ) -> some View {
        let text = message()
        let button = control()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                text.fixedSize()
                Spacer(minLength: 12)
                button
            }
            VStack(alignment: .leading, spacing: 8) {
                text.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                button
            }
        }
    }

    private var optimizeMenu: some View {
        Menu {
            baseButtons
        } label: {
            Label("Optimize for \(store.baseMM.formatted()) mm Base", systemImage: "square.stack.3d.down.right")
        } primaryAction: {
            store.reduce(job, baseMM: store.baseMM)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help(
            "Reduces triangles to the minimum that keeps the deviation within \(store.toleranceMM.formatted()) "
                + "mm at real scale (\(store.detailLevel.name) detail). Creates a copy; the "
                + "current file is unchanged. Pick another base from the menu."
        )
        .accessibilityIdentifier("card.optimize")
    }

    @ViewBuilder private var baseButtons: some View {
        Section("Base Diameter") {
            ForEach(PrintDefaults.baseSizes, id: \.self) { b in
                Button(b == store.baseMM ? "\(b.formatted()) mm Base (Default)" : "\(b.formatted()) mm Base") {
                    store.reduce(job, baseMM: b)
                }
                .disabled(store.hasReduction(of: job, baseMM: b))
            }
        }
        Divider()
        SettingsLink { Text("Printer and Detail Level…") }
    }
}
