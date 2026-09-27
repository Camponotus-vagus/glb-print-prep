import Foundation
import Testing

@testable import GLBPrintPrepCore

@Suite("Detail levels")
struct DetailLevelTests {
    @Test("Tolerances for a 0.2 mm nozzle and 0.08 mm layer match the engine")
    func tolerances() {
        #expect(DetailLevel.extraHigh.tolerance(layer: 0.08, nozzle: 0.2) == 0.01)
        #expect(DetailLevel.high.tolerance(layer: 0.08, nozzle: 0.2) == 0.02)
        #expect(DetailLevel.medium.tolerance(layer: 0.08, nozzle: 0.2) == 0.04)
        #expect(DetailLevel.low.tolerance(layer: 0.08, nozzle: 0.2) == 0.08)
    }

    @Test("The tighter bound wins", arguments: [(0.08, 0.4, 0.02), (0.28, 0.2, 0.02)])
    func tighterBound(layer: Double, nozzle: Double, expected: Double) {
        #expect(DetailLevel.high.tolerance(layer: layer, nozzle: nozzle) == expected)
    }

    @Test func engineNames() {
        #expect(DetailLevel.allCases.map(\.engineName) == ["extra-high", "high", "medium", "low"])
    }
}

@Suite("Engine command line")
struct EngineCommandTests {
    let file = URL(fileURLWithPath: "/tmp/model.glb")

    @Test func repair() {
        let args = EngineCommand.arguments(for: .repair, file: file, previewDir: URL(fileURLWithPath: "/tmp/p"))
        #expect(args == ["--json", "--preview-dir", "/tmp/p", "/tmp/model.glb"])
    }

    @Test("Optimize uses locale-independent decimals")
    func optimize() {
        let args = EngineCommand.arguments(for: .optimize(baseMM: 18.9, toleranceMM: 0.02), file: file, previewDir: nil)
        #expect(
            args == [
                "--json", "--optimize", "--base", "18.9", "--tolerance", "0.02", "--cap", "1000000", "/tmp/model.glb",
            ])
    }
}

@Suite("Engine events")
struct EngineEventTests {
    @Test func stepEvent() throws {
        let event = try #require(
            EngineEvent.parse(#"{"t":"step","file":"/a.glb","step":"read","label":"Reading","progress":0.1}"#))
        #expect(event.t == "step")
        #expect(event.label == "Reading")
        #expect(event.progress == 0.1)
    }

    @Test("Result stats decode with missing counters")
    func partialStats() throws {
        let line =
            #"{"t":"result","status":"OK","stats":{"tris":124037,"trisBefore":1887413,"devMaxMM":0.0177,"withinTolerance":true}}"#
        let event = try #require(EngineEvent.parse(line))
        let stats = try #require(event.stats)
        #expect(stats.tris == 124_037)
        #expect(stats.verts == 0)
        #expect(stats.withinTolerance == true)
        #expect(stats.devMaxMM == 0.0177)
    }

    @Test func nonJSONLinesAreIgnored() {
        #expect(EngineEvent.parse("prune: Removed types") == nil)
        #expect(EngineEvent.parse("") == nil)
    }
}

@Suite("Independent GLB check")
struct GLBCheckTests {
    /// Builds a minimal GLB container around a JSON string.
    func glb(json: String, declaredLength: UInt32? = nil) -> Data {
        var body = Data(json.utf8)
        while body.count % 4 != 0 { body.append(0x20) }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        u32(0x4654_6C67)
        u32(2)
        u32(declaredLength ?? UInt32(12 + 8 + body.count))
        u32(UInt32(body.count))
        u32(0x4E4F_534A)
        data.append(body)
        return data
    }

    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).glb")
        try data.write(to: url)
        return url
    }

    @Test func validFilePasses() throws {
        let url = try write(glb(json: #"{"asset":{"version":"2.0"}}"#))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GLBCheck.problem(with: url) == nil)
    }

    @Test func compressedFileFails() throws {
        let url = try write(glb(json: #"{"asset":{"version":"2.0"},"extensionsUsed":["EXT_meshopt_compression"]}"#))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GLBCheck.problem(with: url) == "still contains EXT_meshopt_compression")
    }

    @Test func wrongLengthFails() throws {
        let url = try write(glb(json: #"{"asset":{"version":"2.0"}}"#, declaredLength: 9999))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GLBCheck.problem(with: url) == "declared length ≠ file size")
    }

    @Test func garbageFails() throws {
        let url = try write(Data("definitely not a glb file".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GLBCheck.problem(with: url) == "missing glTF magic")
    }
}

@Suite("GLB loader")
struct GLBLoaderTests {
    @Test("Rejects files that are not GLB")
    func notGLB() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).glb")
        try Data(repeating: 0, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: GLBError.notGLB) { try await GLBLoader.load(url) }
    }
}
