import Foundation

/// What a queued job does: repair (decompression) or print optimization
/// (adaptive reduction: the fewest triangles whose deviation at real scale stays within tolerance).
public enum JobKind: Equatable, Sendable {
    case repair
    case optimize(baseMM: Double, toleranceMM: Double)

    public var isOptimize: Bool { if case .optimize = self { true } else { false } }
    public var baseMM: Double? { if case .optimize(let base, _) = self { base } else { nil } }
    public var toleranceMM: Double? { if case .optimize(_, let tolerance) = self { tolerance } else { nil } }
}

/// Detail levels (inspired by Bambu Studio) expressed as fractions of layer height and nozzle diameter.
/// Keep in sync with `engine/src/tolerance.mjs`.
public enum DetailLevel: Int, CaseIterable, Identifiable, Sendable {
    case extraHigh, high, medium, low

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .extraHigh: "Extra high"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// The identifier used by the engine's `--detail` option.
    public var engineName: String {
        switch self {
        case .extraHigh: "extra-high"
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        }
    }

    /// tolerance = min(layer × a, nozzle × b), rounded to the micrometre.
    public func tolerance(layer: Double, nozzle: Double) -> Double {
        let a: Double
        let b: Double
        switch self {
        case .extraHigh: a = 0.125; b = 0.05
        case .high: a = 0.25; b = 0.1
        case .medium: a = 0.5; b = 0.2
        case .low: a = 1.0; b = 0.4
        }
        let t: Double = min(layer * a, nozzle * b)
        return (t * 1000).rounded() / 1000
    }
}

public enum PrintDefaults {
    /// Above this, Bambu Studio suggests simplifying the model.
    public static let heavyTriangleThreshold = 1_000_000
    /// Upper bound for optimized output.
    public static let triangleCap = 1_000_000
    /// Common miniature base diameters (mm).
    public static let baseSizes: [Double] = [25, 28, 32, 40, 50, 60]
    public static let nozzleSizes: [Double] = [0.2, 0.4, 0.6, 0.8]
    public static let layerHeights: [Double] = [0.04, 0.06, 0.08, 0.10, 0.12, 0.16, 0.20, 0.24, 0.28]
}

/// Command-line arguments for one engine run (after the script path).
public enum EngineCommand {
    public static func arguments(for kind: JobKind, file: URL, previewDir: URL?) -> [String] {
        var args = ["--json"]
        if let previewDir { args += ["--preview-dir", previewDir.path] }
        if case .optimize(let base, let tolerance) = kind {
            args += [
                "--optimize", "--base", format(base), "--tolerance", format(tolerance),
                "--cap", String(PrintDefaults.triangleCap),
            ]
        }
        return args + [file.path]
    }

    /// Locale-independent decimal formatting ("0.02", never "0,02").
    static func format(_ value: Double) -> String {
        value.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6)))
    }
}
