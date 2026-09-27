import Foundation

/// One NDJSON event emitted by the engine in `--json` mode.
/// See `docs/how-it-works.md` for the protocol.
public struct EngineEvent: Decodable, Sendable {
    public struct Stats: Decodable, Sendable {
        public var verts = 0
        public var tris = 0
        public var points = 0
        public var textures = 0
        public var materials = 0
        public var meshes = 0
        public var inSize = 0
        public var outSize = 0
        public var maxErr = 0.0
        // print optimization only
        public var trisBefore: Int?
        public var devMaxMM: Double?
        public var devMeanMM: Double?
        public var devP99MM: Double?
        public var tolMM: Double?
        public var baseMM: Double?
        public var baseDetected: Bool?
        public var heightMM: Double?
        public var withinTolerance: Bool?
        public var finsRemoved: Int?
        public var iterations: Int?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case verts, tris, points, textures, materials, meshes, inSize, outSize, maxErr
            case trisBefore, devMaxMM, devMeanMM, devP99MM, tolMM, baseMM, baseDetected, heightMM
            case withinTolerance, finsRemoved, iterations
        }

        /// Every field is optional on the wire: missing counters decode as zero.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            verts = try c.decodeIfPresent(Int.self, forKey: .verts) ?? 0
            tris = try c.decodeIfPresent(Int.self, forKey: .tris) ?? 0
            points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 0
            textures = try c.decodeIfPresent(Int.self, forKey: .textures) ?? 0
            materials = try c.decodeIfPresent(Int.self, forKey: .materials) ?? 0
            meshes = try c.decodeIfPresent(Int.self, forKey: .meshes) ?? 0
            inSize = try c.decodeIfPresent(Int.self, forKey: .inSize) ?? 0
            outSize = try c.decodeIfPresent(Int.self, forKey: .outSize) ?? 0
            maxErr = try c.decodeIfPresent(Double.self, forKey: .maxErr) ?? 0
            trisBefore = try c.decodeIfPresent(Int.self, forKey: .trisBefore)
            devMaxMM = try c.decodeIfPresent(Double.self, forKey: .devMaxMM)
            devMeanMM = try c.decodeIfPresent(Double.self, forKey: .devMeanMM)
            devP99MM = try c.decodeIfPresent(Double.self, forKey: .devP99MM)
            tolMM = try c.decodeIfPresent(Double.self, forKey: .tolMM)
            baseMM = try c.decodeIfPresent(Double.self, forKey: .baseMM)
            baseDetected = try c.decodeIfPresent(Bool.self, forKey: .baseDetected)
            heightMM = try c.decodeIfPresent(Double.self, forKey: .heightMM)
            withinTolerance = try c.decodeIfPresent(Bool.self, forKey: .withinTolerance)
            finsRemoved = try c.decodeIfPresent(Int.self, forKey: .finsRemoved)
            iterations = try c.decodeIfPresent(Int.self, forKey: .iterations)
        }
    }

    /// Event type: ready, start, step, stepDone, progress, test, diag, tmp, log, result.
    public let t: String
    public var file: String?
    public var step: String?
    public var label: String?
    public var progress: Double?
    public var ms: Int?
    public var status: String?
    public var detail: String?
    public var out: String?
    public var preview: String?
    public var stats: Stats?
    public var id: String?
    public var ok: Bool?
    public var msg: String?
    public var extensions: [String]?
    public var path: String?
    public var triangles: Int?
    public var version: String?

    /// Decodes one line; returns nil for anything that is not a JSON event.
    public static func parse(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EngineEvent.self, from: data)
    }
}
