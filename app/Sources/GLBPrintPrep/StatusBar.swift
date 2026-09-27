import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Floating status bar (Liquid Glass, functional layer)

struct StatusBar: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let running = store.isRunning
            let c = store.counts
            let f = store.batchFraction
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    summary(running: running, c: c, f: f, now: ctx.date)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("summary", in: glass)

                    // Primary action: morphs between "Stop" and "Clear List"
                    if running {
                        actionButton("Stop All", systemImage: "stop.fill", tint: .red) { store.cancelAll() }
                            .keyboardShortcut(".", modifiers: .command)
                            .help("Stops processing: originals stay untouched (⌘.)")
                            .glassEffectID("stop", in: glass)
                    } else {
                        actionButton("Clear List", systemImage: "checkmark", tint: nil) {
                            withAnimation { store.clearFinished() }
                        }
                        .help("Removes finished files from the list (files on disk are not touched)")
                        .glassEffectID("clear", in: glass)
                    }
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: running)
        }
    }

    @ViewBuilder
    private func summary(
        running: Bool, c: (ok: Int, skipped: Int, failed: Int, done: Int, total: Int), f: Double, now: Date
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if running {
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.small)
                } else {
                    Image(systemName: c.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(c.failed > 0 ? Color.orange : Color.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(running ? "Processing" : "Done").font(.headline)
                    Text(f, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    if running { Pulse(now: now) }
                }
                if running { ProgressView(value: f).progressViewStyle(.linear) }
                HStack(spacing: 14) {
                    Text("\(c.done) of \(c.total) files")
                    Text("Elapsed \(fmt(store.batchElapsed))")
                    if running { Text("Remaining " + (store.etaSmoothed.map { "~" + fmt($0) } ?? "estimating…")) }
                    Text("✓ \(c.ok)   – \(c.skipped)   ✗ \(c.failed)")
                        .accessibilityLabel("\(c.ok) done, \(c.skipped) already fine, \(c.failed) errors")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 720)
    }

    /// Custom control with interactive glass (reacts to pointer and clicks like system buttons).
    private func actionButton(_ title: String, systemImage: String, tint: Color?, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
        .accessibilityLabel(title)
    }
}

/// Aggregate "the engine is alive" indicator: real CPU and RAM of the Node processes.
struct Pulse: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let now: Date
    var body: some View {
        let jobs = store.runningJobs
        let cpu = jobs.reduce(0) { $0 + $1.cpuPercent }
        let mem = jobs.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let silence = jobs.map { now.timeIntervalSince($0.lastEventAt) }.min() ?? 0
        let alive = cpu > 5 || silence < 3
        let color: Color = alive ? .green : (silence < 20 ? .orange : .red)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.4]) { v, p in
                    v.opacity(alive && !reduceMotion ? p : 1)
                } animation: { _ in
                    .easeInOut(duration: 0.6)
                }
            Text(
                mem > 0
                    ? "CPU \(Int(cpu.rounded()))% · \(Int64(mem).formatted(.byteCount(style: .memory)))" : "starting…"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(alive ? "Engine active" : "Engine idle for \(Int(silence)) seconds")
        .help(alive ? "The engine is working (real CPU use of its processes)" : "No recent activity")
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
                Text("CPU \(Int(job.cpuPercent.rounded()))%")
                Text(Int64(job.memoryBytes), format: .byteCount(style: .memory))
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
