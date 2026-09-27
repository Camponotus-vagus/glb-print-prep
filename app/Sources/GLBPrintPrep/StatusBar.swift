import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Floating status bar (Liquid Glass, functional layer)

struct StatusBar: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    /// Diameter of the action button. The summary capsule uses the same minimum height,
    /// so the two glass shapes share top, bottom and centre line.
    private let barHeight: CGFloat = 56
    private let gap: CGFloat = 12

    var body: some View {
        let running = store.isRunning
        // The container spacing equals the gap: the shapes stay separate at rest
        // but morph as one layer when the action button changes.
        GlassEffectContainer(spacing: gap) {
            HStack(spacing: gap) {
                // Only the text needs a clock. The schedule is paused once the batch ends,
                // so a finished list is not re-rendered twice a second; glass stays outside it.
                TimelineView(.animation(minimumInterval: 0.5, paused: !running)) { ctx in
                    summary(running: running, now: ctx.date)
                }
                .padding(.leading, 12).padding(.trailing, 20).padding(.vertical, 8)
                .frame(maxWidth: 720, minHeight: barHeight)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("summary", in: glass)

                // Primary action: one glass circle that morphs between "Stop All" and "Clear List".
                if running {
                    actionButton("Stop All", systemImage: "stop.fill", tint: .red) { store.cancelAll() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop all processing (⌘.). Originals stay untouched.")
                        .accessibilityHint("Stops every file in the queue. Originals stay untouched.")
                        .accessibilityIdentifier("status.stop")
                } else {
                    actionButton("Clear List", systemImage: "xmark", tint: nil) {
                        withAnimation(reduceMotion ? nil : .smooth) { store.clearFinished() }
                    }
                    .help("Remove finished files from the list. Files on disk are not touched.")
                    .accessibilityHint("Removes finished files from the list. Files on disk are not touched.")
                    .accessibilityIdentifier("status.clear")
                }
            }
        }
        // Breathing room below the scroll-edge line of the bar.
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: running)
    }

    private func summary(running: Bool, now: Date) -> some View {
        let c = store.counts
        let f = store.batchFraction
        let percent = Int((f * 100).rounded(.down))
        return HStack(spacing: 12) {
            ZStack {
                if running {
                    // Single progress indicator: the percentage is spelled out next to "Processing".
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.regular)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: c.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(c.failed > 0 ? Color.orange : Color.green)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel(c.failed > 0 ? "Finished with errors" : "Finished")
                }
            }
            .frame(width: 32, height: 32)

            // Two lines in both states, so the capsule never changes height.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if running {
                        Text("Processing").font(.headline)
                        Text("\(percent)%")
                            .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(percent)))
                            .animation(reduceMotion ? nil : .snappy, value: percent)
                    } else {
                        Text("Done").font(.headline)
                        Text(
                            (store.jobs.count > c.total ? "Last batch: " : "")
                                + "\(c.total) \(c.total == 1 ? "file" : "files") in \(fmt(store.batchElapsed))"
                        )
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if running { Pulse(now: now) }
                }
                .lineLimit(1)

                HStack(spacing: 14) {
                    if running {
                        // Drops the least important parts first when the window is narrow.
                        ViewThatFits(in: .horizontal) {
                            Text(progressLine(c, full: true))
                            Text(progressLine(c, full: false))
                            Text("\(c.done)/\(c.total)")
                        }
                        .layoutPriority(-1)
                    }
                    BatchCounts(ok: c.ok, skipped: c.skipped, failed: c.failed)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private func progressLine(_ c: (ok: Int, skipped: Int, failed: Int, done: Int, total: Int), full: Bool)
        -> String
    {
        let remaining: String
        if let eta = store.etaSmoothed {
            remaining = eta < 1 ? "finishing…" : "about \(fmt(eta)) left"
        } else {
            remaining = "estimating…"
        }
        let files = "\(c.done) of \(c.total) files"
        return full
            ? "\(files) · \(fmt(store.batchElapsed)) elapsed · \(remaining)" : "\(files) · \(remaining)"
    }

    /// Circular control with interactive glass (reacts to pointer and clicks like system buttons).
    private func actionButton(_ title: String, systemImage: String, tint: Color?, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .frame(width: barHeight, height: barHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
        .glassEffectID("action", in: glass)
        .accessibilityLabel(title)
    }
}

/// Batch outcome counts as SF Symbols with numbers (repaired / already fine / failed).
private struct BatchCounts: View {
    let ok: Int
    let skipped: Int
    let failed: Int

    var body: some View {
        HStack(spacing: 12) {
            item(ok, symbol: "checkmark.circle", tint: ok > 0 ? .green : .secondary, help: "Repaired and verified")
            item(skipped, symbol: "equal.circle", tint: .secondary, help: "Already fine: no repair needed")
            item(failed, symbol: "xmark.circle", tint: failed > 0 ? .red : .secondary, help: "Failed or cancelled")
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ok) repaired, \(skipped) already fine, \(failed) failed")
    }

    private func item(_ n: Int, symbol: String, tint: Color, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(n, format: .number).contentTransition(.numericText(value: Double(n)))
        }
        .help(help)
    }
}

/// Aggregate "the engine is alive" indicator: real CPU and RAM of the Node processes.
struct Pulse: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let now: Date
    var body: some View {
        let jobs = store.runningJobs
        let cpu = min(100, jobs.reduce(0) { $0 + $1.cpuPercent })
        let memBytes = jobs.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let mem = Store.memoryShare(memBytes)
        let silence = jobs.map { now.timeIntervalSince($0.lastEventAt) }.min() ?? 0
        let alive = cpu > 5 || silence < 3
        let color: Color = alive ? .green : (silence < 20 ? .orange : .red)
        let usage: String? =
            memBytes > 0 ? "CPU \(percentText(cpu)) · RAM \(percentText(mem))" : nil
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.4]) { v, p in
                    v.opacity(alive && !reduceMotion ? p : 1)
                } animation: { _ in
                    .easeInOut(duration: 0.6)
                }
            // Fixed minimum width, trailing-aligned: changing CPU/RAM digits don't shift the row.
            Text(usage ?? "starting…")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 118, alignment: .trailing)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alive ? "Engine active" : "Engine idle for \(Int(silence)) seconds")
        .accessibilityValue(usage ?? "Starting")
        .help(
            alive
                ? "The engine is working. CPU: share of the Mac's total processing power (all cores); "
                    + "RAM: share of its memory (\(memBytes.formatted(.byteCount(style: .memory))))."
                : "No recent activity")
    }
}

/// Per-file heartbeat (inside the card: content layer, so no glass).
struct HeartbeatRow: View {
    let job: FileJob
    let now: Date
    var body: some View {
        let silence = now.timeIntervalSince(job.lastEventAt)
        let busy = job.cpuPercent > 5
        HStack(spacing: 12) {
            Label(job.pid.map { "pid \($0)" } ?? "—", systemImage: "cpu")
            if job.memoryBytes > 0 {
                Text("CPU \(percentText(job.cpuPercent))")
                Text("RAM \(percentText(job.memoryPercent))")
                    .help(Int64(job.memoryBytes).formatted(.byteCount(style: .memory)))
            } else {
                Text("CPU —"); Text("RAM —")
            }
            Text(silence < 1 ? "last signal now" : "last signal \(Int(silence)) s ago")
                .foregroundStyle(silence < 20 || busy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// 0–100 → "37%"; small non-zero values read "<1%" rather than a misleading "0%".
func percentText(_ value: Double) -> String {
    if value > 0 && value < 1 { return "<1%" }
    return "\(Int(value.rounded()))%"
}
