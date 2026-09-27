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
    @State private var width: CGFloat = 800
    /// Compact layout when the column is narrow (small window or inspector open)
    private var compact: Bool { width < 640 }

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
                HStack(alignment: .firstTextBaseline) {
                    Text(job.kind.isOptimize ? (job.outURL?.lastPathComponent ?? job.name) : job.name)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(job.name)
                    if !compact {
                        ForEach(job.extensions, id: \.self) { ext in
                            Text(
                                ext.replacingOccurrences(of: "EXT_", with: "").replacingOccurrences(
                                    of: "KHR_", with: "")
                            )
                            .font(.caption2.weight(.medium)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.fill.tertiary, in: .capsule)
                        }
                    }
                }
                sizes
                statusLine
                if job.state == .running {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        VStack(alignment: .leading, spacing: 5) {
                            ProgressView(value: job.progress)
                            HStack {
                                Text(job.progress, format: .percent.precision(.fractionLength(0)))
                                Text("· elapsed \(fmt(job.elapsed))")
                                if let eta = job.eta { Text("· ~\(fmt(eta)) remaining") }
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HeartbeatRow(job: job, now: ctx.date)
                        }
                    }
                }
                if job.state == .ok, let s = job.stats { statsLine(s) }
                if job.state == .ok && !job.kind.isOptimize { trashLine }
                if job.state == .ok && job.kind.isOptimize && job.trashedURL != nil {
                    HStack(spacing: 8) {
                        Label("Non-optimized version moved to the Trash", systemImage: "trash").font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Restore") { store.restoreOriginal(job) }.buttonStyle(.link)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(14)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .containerShape(.rect(cornerRadius: 22))  // → thumbnail concentric with the card
        .animation(.snappy, value: job.state)
    }

    @ViewBuilder private var thumbnail: some View {
        switch job.state {
        case .ok:
            if let url = job.previewURL ?? job.outURL {
                ModelThumbnail(url: url)
                    .onTapGesture { openViewer() }
                    .help("Click to open the full 3D preview")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Preview of \(job.name)")
            }
        case .running:
            ZStack {
                Rectangle().fill(.quinary)
                ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.large)
            }
        default:
            ZStack {
                Rectangle().fill(.quinary)
                Image(systemName: icon).font(.system(size: 38)).foregroundStyle(iconColor)
            }
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: job.kind.isOptimize ? "square.stack.3d.down.right" : "clock"
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

    private var sizes: some View {
        HStack(spacing: 6) {
            Text(job.size, format: .byteCount(style: .file))
            if let s = job.stats, s.outSize > 0 {
                Image(systemName: "arrow.right").font(.caption)
                Text(Int64(s.outSize), format: .byteCount(style: .file))
                if let out = job.outURL, !compact, !job.kind.isOptimize {
                    Text("· \(out.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .running:
                ProgressView().controlSize(.small)
                Text(job.stepLabel)
                if let s = job.stepStartedAt {
                    Text(s, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                }
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(job.stepLabel)
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(m).textSelection(.enabled)
            case .skipped: Image(systemName: "equal.circle.fill").foregroundStyle(.secondary); Text(job.stepLabel)
            case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.orange); Text(job.stepLabel)
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary); Text("Queued")
            }
        }
        .font(.callout)
    }

    private func statsLine(_ s: EngineEvent.Stats) -> some View {
        if job.kind.isOptimize, let before = s.trisBefore {
            let saved = 1 - Double(s.tris) / Double(max(before, 1))
            let mm = { (x: Double?) in String(format: "%.3f mm", x ?? 0) }
            let height = s.heightMM.map { String(format: "%.1f mm", $0) } ?? "?"
            let base = (s.baseDetected ?? false) ? "base detected" : "base estimated from footprint"
            return Text(
                "\(before.formatted()) → \(s.tris.formatted()) triangles (−\(saved.formatted(.percent.precision(.fractionLength(0))))) "
                    + "· miniature \(height) tall (\(base)) · max deviation \(mm(s.devMaxMM)), "
                    + "99% ≤ \(mm(s.devP99MM)), mean \(String(format: "%.4f mm", s.devMeanMM ?? 0)) "
                    + "· in \(fmt(job.elapsed))"
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        var parts = ["\(s.verts.formatted()) vertices"]
        if s.tris > 0 { parts.append("\(s.tris.formatted()) triangles") }
        if s.points > 0 { parts.append("\(s.points.formatted()) points") }
        parts.append("\(s.textures) texture\(s.textures == 1 ? "" : "s")")
        parts.append("in \(fmt(job.elapsed))")
        return Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var trashLine: some View {
        if job.trashedURL != nil {
            HStack(spacing: 8) {
                Label("Original moved to the Trash", systemImage: "trash").font(.callout).foregroundStyle(.secondary)
                Button("Restore") { store.restoreOriginal(job) }.buttonStyle(.link)
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
                        Image(systemName: s.ms == nil ? "circle.dotted" : "checkmark")
                            .foregroundStyle(s.ms == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                        Text(s.label)
                        Text(s.ms.map { "\($0) ms" } ?? "…").monospacedDigit().foregroundStyle(.secondary)
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

    // Standard controls in the content layer (no custom glass)
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if job.state == .ok && !job.outSuperseded {
                Button {
                    openViewer()
                } label: {
                    Label("3D Preview", systemImage: "cube")
                }
                if let out = job.outURL {
                    Button {
                        store.revealInFinder(out)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            }
            if job.state == .running || job.state == .queued {
                Button(role: .destructive) {
                    store.cancel(job)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .labelStyle(AdaptiveLabelStyle(compact: compact))
        .fixedSize()
    }

    private func openViewer() {
        guard let out = job.outURL else { return }
        openWindow(id: "viewer", value: ViewerTarget(url: out, title: out.lastPathComponent))
    }
}

/// Icon only in narrow columns (the title remains for accessibility and tooltips).
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
        HStack(spacing: 10) {
            switch red?.state {
            case .ok?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Print-ready version: \((red?.stats?.tris ?? 0).formatted()) triangles")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu("Another Base") { baseButtons }
                    .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            case .running?, .queued?:
                ProgressView().controlSize(.small)
                Text("Optimizing for print…").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            default:
                Image(systemName: "printer").foregroundStyle(.orange)
                Text("\((job.triangles ?? 0).formatted()) triangles: slicers like Bambu Studio recommend simplifying")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
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
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .animation(.snappy, value: red?.state)
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
