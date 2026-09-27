import AppKit
import Darwin
import Foundation
import GLBPrintPrepCore
import Observation

// MARK: - A queued file

enum JobState: Equatable {
    case queued, running, ok, skipped, failed(String), cancelled
    var isFinished: Bool { !(self == .queued || self == .running) }
}

struct StepRecord: Identifiable {
    let id: String
    let label: String
    var ms: Int?
}

struct TestRecord: Identifiable {
    let id: String
    let label: String
}

@Observable @MainActor
final class FileJob: Identifiable {
    let id = UUID()
    let url: URL
    let kind: JobKind
    let size: Int64
    var triangles: Int?
    var state: JobState = .queued
    var progress: Double = 0
    var stepLabel = "Queued"
    var stepStartedAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var steps: [StepRecord] = []
    var tests: [TestRecord] = []
    var extensions: [String] = []
    var stats: EngineEvent.Stats?
    var outURL: URL?
    var previewURL: URL?
    var trashedURL: URL?
    var restored = false
    var trashError: String?
    /// The file produced by this repair was replaced by its optimized version (and moved to the Trash).
    var outSuperseded = false
    var lastEventAt = Date()
    // process telemetry (heartbeat)
    var pid: pid_t?
    /// Share of the whole Mac's CPU capacity (all cores together), 0–100.
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    /// Share of the Mac's physical memory, 0–100.
    var memoryPercent: Double { Store.memoryShare(memoryBytes) }
    fileprivate var lastCPUTime: UInt64 = 0
    fileprivate var lastSampleAt: Date?
    fileprivate var tmpPath: String?
    fileprivate var process: Process?

    init(url: URL, kind: JobKind = .repair) {
        self.url = url
        self.kind = kind
        self.size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    var name: String { url.lastPathComponent }

    /// The produced file (or, if skipped, the original): the source for an optional optimization.
    var currentFile: URL? {
        switch state {
        case .ok: outSuperseded ? nil : outURL
        case .skipped: !outSuperseded && FileManager.default.fileExists(atPath: url.path) ? url : nil
        default: nil
        }
    }

    var isHeavy: Bool { (triangles ?? 0) > PrintDefaults.heavyTriangleThreshold }
    /// Weight for overall progress: file size plus a fixed cost (Node startup, validator).
    var weight: Double { Double(size) + 3_000_000 }

    var elapsed: TimeInterval {
        guard let start = startedAt else { return 0 }
        return (finishedAt ?? .now).timeIntervalSince(start)
    }

    var eta: TimeInterval? {
        guard state == .running, progress > 0.04 else { return nil }
        return elapsed * (1 - progress) / progress
    }
}

// MARK: - Store

@Observable @MainActor
final class Store {
    static let shared = Store()
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.camponotus-vagus.glb-print-prep"

    var jobs: [FileJob] = []
    var log: [String] = []
    var showImporter = false
    var setupError: String?

    /// Keep only optimized versions: after a successful optimization within tolerance, the
    /// source (non-optimized) file goes to the Trash. Off by default.
    var trashUnoptimized: Bool = Store.stored("trashUnoptimized", false) {
        didSet { UserDefaults.standard.set(trashUnoptimized, forKey: "trashUnoptimized") }
    }
    var trashOriginals: Bool = Store.stored("trashOriginals", true) {
        didSet { UserDefaults.standard.set(trashOriginals, forKey: "trashOriginals") }
    }
    // 3D printing
    var offerReduction: Bool = Store.stored("offerReduction", true) {
        didSet { UserDefaults.standard.set(offerReduction, forKey: "offerReduction") }
    }
    var autoReduce: Bool = Store.stored("autoReduce", false) {
        didSet { UserDefaults.standard.set(autoReduce, forKey: "autoReduce") }
    }
    /// Thumbnails rotate only on hover by default (cheaper); this makes them rotate all the time.
    var alwaysSpinThumbnails: Bool = Store.stored("alwaysSpinThumbnails", false) {
        didSet { UserDefaults.standard.set(alwaysSpinThumbnails, forKey: "alwaysSpinThumbnails") }
    }
    /// Default base diameter (mm): gives the miniature its real-world scale.
    var baseMM: Double = Store.stored("baseMM", 32.0) {
        didSet { UserDefaults.standard.set(baseMM, forKey: "baseMM") }
    }
    var nozzleMM: Double = Store.stored("nozzleMM", 0.2) {
        didSet { UserDefaults.standard.set(nozzleMM, forKey: "nozzleMM") }
    }
    var layerMM: Double = Store.stored("layerMM", 0.08) {
        didSet { UserDefaults.standard.set(layerMM, forKey: "layerMM") }
    }
    var detailLevel: DetailLevel = DetailLevel(rawValue: Store.stored("detailLevel", 1)) ?? .high {
        didSet { UserDefaults.standard.set(detailLevel.rawValue, forKey: "detailLevel") }
    }
    var toleranceMM: Double { detailLevel.tolerance(layer: layerMM, nozzle: nozzleMM) }

    private(set) var batchStart: Date?
    private(set) var batch: [FileJob] = []
    private(set) var etaSmoothed: TimeInterval?
    private var heartbeat: Task<Void, Never>?

    nonisolated private static func stored<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    /// Parallelism tuned for Apple Silicon: half the performance cores, bounded by RAM
    /// (a model of ~60 MB once decompressed peaks at ~1.5 GB in the engine).
    let maxParallel: Int = {
        let pCores = Store.sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(1, min(pCores / 2, ramGB / 8, 4))
    }()

    let previewDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Store.bundleID)/previews", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)  // previews from the previous session
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The Node.js runtime bundled inside the app, or a system installation as a fallback.
    @ObservationIgnored let nodeURL: URL? = {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node/bin/node") { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    var engineURL: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("engine/bin/glb-print-prep.mjs") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    // MARK: aggregate state

    var isRunning: Bool { jobs.contains { $0.state == .running || $0.state == .queued } }

    var batchFraction: Double {
        let total = batch.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let done = batch.reduce(0.0) { acc, job in
            acc + job.weight * (job.state.isFinished ? 1 : job.progress)
        }
        return min(1, done / total)
    }

    var batchElapsed: TimeInterval {
        guard let start = batchStart else { return 0 }
        let end = isBatchActive ? Date.now : (batch.compactMap(\.finishedAt).max() ?? .now)
        return end.timeIntervalSince(start)
    }

    var counts: (ok: Int, skipped: Int, failed: Int, done: Int, total: Int) {
        var ok = 0
        var skipped = 0
        var failed = 0
        for job in batch {
            switch job.state {
            case .ok: ok += 1
            case .skipped: skipped += 1
            case .failed, .cancelled: failed += 1
            default: break
            }
        }
        return (ok, skipped, failed, ok + skipped + failed, batch.count)
    }

    var runningJobs: [FileJob] { jobs.filter { $0.state == .running } }

    // MARK: actions

    func add(_ urls: [URL]) {
        var added = 0
        for url in expandFolders(urls) {
            let u = url.standardizedFileURL
            guard u.pathExtension.lowercased() == "glb" else {
                appendLog("Ignored (not a .glb): \(u.lastPathComponent)")
                continue
            }
            if jobs.contains(where: { $0.url == u && !$0.state.isFinished }) { continue }
            let job = FileJob(url: u)
            jobs.append(job)
            if !isBatchActive { resetBatch() }
            batch.append(job)
            added += 1
        }
        if added > 0 {
            appendLog("Added \(added) file\(added == 1 ? "" : "s") to the queue")
            pump()
        }
    }

    private var isBatchActive: Bool { batch.contains { !$0.state.isFinished } }

    private func resetBatch() {
        batch = []
        batchStart = nil
        etaSmoothed = nil
    }

    /// Replaces folders with every .glb they contain (subfolders included),
    /// skipping hidden files, packages and temporary `.partial` files.
    private func expandFolders(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else {
                out.append(url)
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard
                let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            var found: [URL] = []
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "glb" {
                if (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true { found.append(file) }
            }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            appendLog("Folder \(url.lastPathComponent): found \(found.count) .glb file\(found.count == 1 ? "" : "s")")
            out += found
        }
        return out
    }

    /// Queues print optimization of the file produced by `job` (never modifies or deletes anything).
    func reduce(_ job: FileJob, baseMM: Double, automatic: Bool = false) {
        guard let source = job.currentFile else { return }
        guard !hasReduction(of: job, baseMM: baseMM) else { return }
        let reduction = FileJob(url: source, kind: .optimize(baseMM: baseMM, toleranceMM: toleranceMM))
        reduction.triangles = job.triangles
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs.insert(reduction, at: i + 1)
        } else {
            jobs.append(reduction)
        }
        // automatic optimization continues the repair's batch (single timing and counters)
        if !isBatchActive && !(automatic && batch.contains { $0.id == job.id }) { resetBatch() }
        batch.append(reduction)
        appendLog(
            "Optimization queued: \(source.lastPathComponent) → base Ø \(baseMM.formatted()) mm, "
                + "tolerance \(toleranceMM.formatted()) mm")
        pump()
    }

    func hasReduction(of job: FileJob, baseMM: Double) -> Bool {
        guard let source = job.currentFile else { return false }
        let kind = JobKind.optimize(baseMM: baseMM, toleranceMM: toleranceMM)
        return jobs.contains { $0.kind == kind && $0.url == source && $0.state != .cancelled && !isFailed($0) }
    }

    /// The latest (not failed/cancelled) optimization linked to the file produced by `job`.
    func reduction(of job: FileJob) -> FileJob? {
        guard let source = job.currentFile else { return nil }
        return jobs.last { $0.kind.isOptimize && $0.url == source && $0.state != .cancelled && !isFailed($0) }
    }

    private func isFailed(_ job: FileJob) -> Bool { if case .failed = job.state { true } else { false } }

    func canOfferReduction(_ job: FileJob) -> Bool {
        offerReduction && job.kind == .repair && job.isHeavy && job.currentFile != nil
    }

    func cancel(_ job: FileJob) {
        switch job.state {
        case .queued:
            markCancelled(job)
        case .running:
            job.process?.terminate()  // SIGTERM: the engine has not touched the original yet
        default: break
        }
        pump()
    }

    func cancelAll() {
        for job in jobs where job.state == .queued { markCancelled(job) }
        for job in jobs where job.state == .running { job.process?.terminate() }
    }

    private func markCancelled(_ job: FileJob) {
        job.state = .cancelled
        job.stepLabel = "Cancelled"
        job.finishedAt = .now
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        if !isBatchActive {
            batch = []
            batchStart = nil
        }
    }

    func restoreOriginal(_ job: FileJob) {
        guard let trashed = job.trashedURL else { return }
        do {
            try FileManager.default.moveItem(at: trashed, to: job.url)
            job.restored = true
            job.trashedURL = nil
            for parent in jobs where parent.kind == .repair && (parent.outURL ?? parent.url) == job.url {
                parent.outSuperseded = false
            }
            appendLog("Restored from the Trash: \(job.name)")
        } catch {
            appendLog("Could not restore \(job.name): \(error.localizedDescription)")
        }
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: scheduler

    private func pump() {
        guard setupError == nil else { return }
        while runningJobs.count < maxParallel, let next = jobs.first(where: { $0.state == .queued }) {
            if batchStart == nil { batchStart = .now }
            next.state = .running
            next.startedAt = .now
            next.stepLabel = "Starting the engine…"
            Task { await run(next) }
        }
        startHeartbeatIfNeeded()
    }

    private func run(_ job: FileJob) async {
        guard let node = nodeURL else {
            setupError =
                "Node.js was not found. The app normally bundles it; otherwise install it with: brew install node"
            fail(job, "Node.js not found")
            return
        }
        guard let engine = engineURL else {
            fail(job, "The engine is missing from the app bundle")
            return
        }

        let process = Process()
        process.executableURL = node
        process.arguments =
            ["--max-old-space-size=8192", engine.path]
            + EngineCommand.arguments(for: job.kind, file: job.url, previewDir: previewDir)
        process.currentDirectoryURL = engine.deletingLastPathComponent()
        process.qualityOfService = .userInitiated  // P-cores on Apple Silicon, but yields to the UI
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { proc in
            exitContinuation.yield(proc.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            fail(job, "Could not start Node: \(error.localizedDescription)")
            return
        }
        job.process = process
        job.pid = process.processIdentifier
        appendLog("▶︎ \(job.name) (pid \(process.processIdentifier))")

        // stderr → log
        let errLines = LineStream(err.fileHandleForReading)
        let errTask = Task {
            for await line in errLines.stream { self.appendLog("[engine] \(line)") }
        }

        var result: EngineEvent?
        for await line in LineStream(out.fileHandleForReading).stream {
            guard let event = EngineEvent.parse(line) else {
                if !line.isEmpty { appendLog("[engine] \(line)") }
                continue
            }
            handle(event, job: job)
            if event.t == "result" { result = event }
        }

        var status: Int32 = -1
        for await s in exitStream { status = s }
        await errTask.value
        job.process = nil
        job.pid = nil

        if process.terminationReason == .uncaughtSignal {
            if let tmp = job.tmpPath { try? FileManager.default.removeItem(atPath: tmp) }
            job.state = .cancelled
            job.stepLabel = job.kind.isOptimize ? "Cancelled, no file written" : "Cancelled, original untouched"
            job.finishedAt = .now
            appendLog("■ \(job.name): cancelled")
        } else if let result {
            finish(job, with: result)
        } else {
            fail(job, "The engine exited without a result (code \(status))")
        }
        pump()
    }

    private func handle(_ event: EngineEvent, job: FileJob) {
        job.lastEventAt = .now
        switch event.t {
        case "step":
            job.stepLabel = event.label ?? event.step ?? ""
            job.stepStartedAt = .now
            if let p = event.progress { job.progress = p }
            if let id = event.step, let label = event.label { job.steps.append(StepRecord(id: id, label: label)) }
        case "stepDone":
            if let i = job.steps.lastIndex(where: { $0.id == event.step }) { job.steps[i].ms = event.ms }
        case "progress":
            if let p = event.progress { job.progress = max(job.progress, p) }
        case "test":
            if let id = event.id, let label = event.label { job.tests.append(TestRecord(id: id, label: label)) }
        case "diag":
            job.extensions = event.extensions ?? []
            if let t = event.triangles { job.triangles = t }
        case "tmp":
            job.tmpPath = event.path
        case "log":
            if let message = event.msg { appendLog("\(job.name): \(message)") }
        default: break
        }
    }

    private func finish(_ job: FileJob, with result: EngineEvent) {
        job.finishedAt = .now
        job.progress = 1
        job.stats = result.stats
        if let t = result.stats?.tris, t > 0, !job.kind.isOptimize { job.triangles = t }
        if job.kind.isOptimize {
            finishOptimize(job, with: result)
            return
        }
        switch result.status {
        case "OK":
            guard let outPath = result.out else {
                fail(job, "Result without an output file")
                return
            }
            let outURL = URL(fileURLWithPath: outPath)
            job.outURL = outURL
            job.previewURL = result.preview.map(URL.init(fileURLWithPath:))
            // A check independent of the engine before touching the original
            if let problem = GLBCheck.problem(with: outURL) {
                fail(job, "The app's final check failed: \(problem). Original kept.")
                return
            }
            job.state = .ok
            job.stepLabel = "Repaired and verified"
            if trashOriginals {
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: job.url, resultingItemURL: &resulting)
                    job.trashedURL = resulting as URL?
                    appendLog("✓ \(job.name) → \(outURL.lastPathComponent); original moved to the Trash")
                } catch {
                    job.trashError = error.localizedDescription
                    appendLog("✓ \(job.name) repaired, but not moved to the Trash: \(error.localizedDescription)")
                }
            } else {
                appendLog("✓ \(job.name) → \(outURL.lastPathComponent); original kept")
            }
            if autoReduce && job.isHeavy { reduce(job, baseMM: baseMM, automatic: true) }
        case "SKIP":
            job.state = .skipped
            job.stepLabel = result.detail ?? "Nothing to do"
            appendLog("– \(job.name): \(job.stepLabel)")
            if autoReduce && job.isHeavy { reduce(job, baseMM: baseMM, automatic: true) }
        default:
            fail(job, result.detail ?? "Unknown error")
        }
    }

    /// Outcome of an optimization: a new file next to the source; nothing is deleted unless
    /// "Keep only optimized versions" is on and the result is within tolerance.
    private func finishOptimize(_ job: FileJob, with result: EngineEvent) {
        switch result.status {
        case "OK":
            guard let outPath = result.out else {
                fail(job, "Result without an output file")
                return
            }
            let outURL = URL(fileURLWithPath: outPath)
            if let problem = GLBCheck.problem(with: outURL) {
                fail(job, "The app's final check failed: \(problem)")
                return
            }
            job.outURL = outURL
            job.previewURL = result.preview.map(URL.init(fileURLWithPath:))
            job.state = .ok
            let within = result.stats?.withinTolerance ?? false
            job.stepLabel =
                within ? "Optimized and verified" : "Optimized (tolerance not reachable within 1 M triangles)"
            appendLog(
                "✓ \(job.name) → \(outURL.lastPathComponent) (\(result.stats?.tris.formatted() ?? "?") triangles)")
            if trashUnoptimized { trashSource(of: job, outURL: outURL, within: within) }
        case "SKIP":
            job.state = .skipped
            job.stepLabel = result.detail ?? "Nothing to reduce"
            appendLog("– \(job.name): \(job.stepLabel)")
        default:
            fail(job, result.detail ?? "Unknown error")
        }
    }

    /// Keep only optimized versions: trash the source file, but only if everything checks out.
    private func trashSource(of job: FileJob, outURL: URL, within: Bool) {
        guard within else {
            appendLog("Non-optimized file kept: the tolerance was not met")
            return
        }
        guard job.url != outURL, FileManager.default.fileExists(atPath: job.url.path) else { return }
        // cards to update: found BEFORE trashing (afterwards the file no longer exists)
        let parents = jobs.filter { $0.kind == .repair && $0.currentFile == job.url }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: job.url, resultingItemURL: &resulting)
            job.trashedURL = resulting as URL?
            for parent in parents { parent.outSuperseded = true }
            appendLog("Non-optimized version moved to the Trash: \(job.name)")
        } catch {
            job.trashError = error.localizedDescription
            appendLog("Could not move \(job.name) to the Trash: \(error.localizedDescription)")
        }
    }

    private func fail(_ job: FileJob, _ message: String) {
        job.state = .failed(message)
        job.stepLabel = message
        job.finishedAt = .now
        appendLog("✗ \(job.name): \(message)")
    }

    func appendLog(_ line: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        log.append("\(timestamp)  \(line)")
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: heartbeat (process CPU/RAM + smoothed ETA)

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil, isRunning else { return }
        heartbeat = Task { [weak self] in
            while let self, self.isRunning {
                self.sample()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.heartbeat = nil
        }
    }

    private func sample() {
        for job in runningJobs {
            guard let pid = job.pid, let usage = Self.rusage(pid) else { continue }
            let now = Date.now
            if let last = job.lastSampleAt, job.lastCPUTime > 0 {
                let cpuNs = Double(usage.cpuNs &- job.lastCPUTime)
                // CPU time / wall time counts one core as 100 %: divide by the core count so the value is
                // a share of the whole machine, like Activity Monitor's "% CPU" divided by cores.
                let perCore = cpuNs / (now.timeIntervalSince(last) * 1e9) * 100
                job.cpuPercent = min(100, max(0, perCore / Double(Self.coreCount)))
            }
            job.lastCPUTime = usage.cpuNs
            job.lastSampleAt = now
            job.memoryBytes = usage.footprint
        }
        let f = batchFraction
        if f > 0.03, f < 1 {
            let raw = batchElapsed * (1 - f) / f
            etaSmoothed = etaSmoothed.map { 0.7 * $0 + 0.3 * raw } ?? raw
        } else if f >= 1 {
            etaSmoothed = 0
        }
    }

    nonisolated private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    nonisolated static func rusage(_ pid: pid_t) -> (cpuNs: UInt64, footprint: UInt64)? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time  // mach units (125/3 ns on Apple Silicon)
        let ns = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        return (ns, info.ri_phys_footprint)
    }

    nonisolated static let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// Bytes → share of physical memory, 0–100.
    nonisolated static func memoryShare(_ bytes: UInt64) -> Double {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(100, Double(bytes) / total * 100) : 0
    }

    nonisolated static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &length, nil, 0) == 0 ? Int(value) : nil
    }
}
