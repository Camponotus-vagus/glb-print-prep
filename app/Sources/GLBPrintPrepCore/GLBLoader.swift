import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import simd

// Minimal but complete GLB loader for *already repaired* files (no compression):
// float/normalized accessors, byteStride, node hierarchy, PBR materials with textures.
// Parsing and image decoding run off the main thread; only RealityKit resource creation
// (SceneBuilder, in the app target) runs on the MainActor.

public struct LoadedModelData: Sendable {
    public struct Prim: Sendable {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]?
        public var uvs: [SIMD2<Float>]?
        public var indices: [UInt32]?
        public var mode: Int
        public var material: Int?
    }
    public struct Mat: Sendable {
        public var baseColor = SIMD4<Float>(1, 1, 1, 1)
        public var metallic: Float = 1
        public var roughness: Float = 1
        public var emissive = SIMD3<Float>(0, 0, 0)
        public var baseTex: SendableImage?
        public var roughTex: SendableImage?
        public var metalTex: SendableImage?
        public var normalTex: SendableImage?
        public var emissiveTex: SendableImage?
        public var doubleSided = false
        public var blend = false
    }
    public var prims: [Prim]
    public var materials: [Mat]
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    public var vertexCount: Int
    public var triangleCount: Int
    public var pointCount: Int
}

/// CGImage is immutable, so sharing it across tasks is safe.
public struct SendableImage: @unchecked Sendable {
    public let cg: CGImage
    public init(cg: CGImage) { self.cg = cg }
}

public enum GLBError: LocalizedError, Equatable {
    case notGLB, badJSON(String), unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .notGLB: "Not a valid GLB file"
        case .badJSON(let s): "Invalid glTF JSON: \(s)"
        case .unsupported(let s): "Not supported in the preview: \(s)"
        }
    }
}

// MARK: - glTF schema (only the fields in use)

private struct GLTFDoc: Decodable {
    struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
    }
    struct BufferView: Decodable { var buffer: Int; var byteOffset: Int?; var byteLength: Int; var byteStride: Int? }
    struct Primitive: Decodable { var attributes: [String: Int]; var indices: Int?; var material: Int?; var mode: Int? }
    struct Mesh: Decodable { var primitives: [Primitive] }
    struct Node: Decodable {
        var children: [Int]?
        var mesh: Int?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
    }
    struct Scene: Decodable { var nodes: [Int]? }
    struct TexRef: Decodable { var index: Int }
    struct PBR: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TexRef?
        var metallicFactor: Float?
        var roughnessFactor: Float?; var metallicRoughnessTexture: TexRef?
    }
    struct Material: Decodable {
        var pbrMetallicRoughness: PBR?
        var normalTexture: TexRef?
        var emissiveTexture: TexRef?
        var emissiveFactor: [Float]?; var alphaMode: String?; var doubleSided: Bool?
    }
    struct Texture: Decodable {
        struct Ext: Decodable { var source: Int? }
        struct Exts: Decodable { var EXT_texture_webp: Ext? }
        var source: Int?
        var extensions: Exts?
        /// effective source: WebP (decoded natively by ImageIO) or a standard image
        var imageIndex: Int? { extensions?.EXT_texture_webp?.source ?? source }
    }
    struct Image: Decodable { var bufferView: Int?; var mimeType: String? }
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var meshes: [Mesh]?
    var nodes: [Node]?
    var scenes: [Scene]?
    var scene: Int?
    var materials: [Material]?
    var textures: [Texture]?
    var images: [Image]?
    var extensionsRequired: [String]?
}

public enum GLBLoader {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Full parse off the main thread (concurrent pool).
    @concurrent
    public static func load(_ url: URL) async throws -> LoadedModelData {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 20 else { throw GLBError.notGLB }
        func u32(_ o: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }) }
        guard u32(0) == 0x46546C67, u32(4) == 2 else { throw GLBError.notGLB }

        var json: Data?
        var bin = Data()
        var off = 12
        while off + 8 <= data.count {
            let len = u32(off), type = u32(off + 4)
            let body = data.subdata(in: (off + 8)..<min(data.count, off + 8 + len))
            if type == 0x4E4F534A { json = body } else if type == 0x004E4942 { bin = body }
            off += 8 + len
        }
        guard let json else { throw GLBError.badJSON("missing JSON chunk") }
        let doc: GLTFDoc
        do { doc = try JSONDecoder().decode(GLTFDoc.self, from: json) } catch {
            throw GLBError.badJSON(error.localizedDescription)
        }
        let compressed = (doc.extensionsRequired ?? []).filter {
            ["EXT_meshopt_compression", "KHR_mesh_quantization", "KHR_draco_mesh_compression"].contains($0)
        }
        if !compressed.isEmpty { throw GLBError.unsupported(compressed.joined(separator: ", ")) }

        let reader = AccessorReader(doc: doc, bin: bin)

        // Textures (decoded once, in parallel)
        let imageCount = doc.images?.count ?? 0
        var decoded = [CGImage?](repeating: nil, count: imageCount)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for i in 0..<imageCount {
                guard let bvi = doc.images?[i].bufferView, let bv = doc.bufferViews?[bvi] else { continue }
                let slice = bin.subdata(in: (bv.byteOffset ?? 0)..<((bv.byteOffset ?? 0) + bv.byteLength))
                group.addTask {
                    guard let src = CGImageSourceCreateWithData(slice as CFData, nil) else { return (i, nil) }
                    return (
                        i,
                        CGImageSourceCreateImageAtIndex(
                            src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    )
                }
            }
            for await (i, img) in group { decoded[i] = img }
        }
        func image(_ ref: GLTFDoc.TexRef?) -> CGImage? {
            guard let ref, let src = doc.textures?[ref.index].imageIndex, src < decoded.count else { return nil }
            return decoded[src]
        }

        // Materials
        var mats: [LoadedModelData.Mat] = []
        for m in doc.materials ?? [] {
            var out = LoadedModelData.Mat()
            if let f = m.pbrMetallicRoughness?.baseColorFactor, f.count == 4 {
                out.baseColor = SIMD4(f[0], f[1], f[2], f[3])
            }
            out.metallic = m.pbrMetallicRoughness?.metallicFactor ?? 1
            out.roughness = m.pbrMetallicRoughness?.roughnessFactor ?? 1
            if let e = m.emissiveFactor, e.count == 3 { out.emissive = SIMD3(e[0], e[1], e[2]) }
            out.baseTex = image(m.pbrMetallicRoughness?.baseColorTexture).map(SendableImage.init)
            if let mr = image(m.pbrMetallicRoughness?.metallicRoughnessTexture) {
                // glTF: G = roughness, B = metallic → RealityKit wants separate single-channel maps
                out.roughTex = channel(mr, 1).map(SendableImage.init)
                out.metalTex = channel(mr, 2).map(SendableImage.init)
            }
            out.normalTex = image(m.normalTexture).map(SendableImage.init)
            out.emissiveTex = image(m.emissiveTexture).map(SendableImage.init)
            out.doubleSided = m.doubleSided ?? false
            out.blend = m.alphaMode == "BLEND"
            mats.append(out)
        }

        // Nodes → world transforms; primitives are baked into world coordinates
        var prims: [LoadedModelData.Prim] = []
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude), bmax = -bmin
        var verts = 0, tris = 0, points = 0
        let nodes = doc.nodes ?? []
        var roots = doc.scenes?[doc.scene ?? 0].nodes ?? []
        if roots.isEmpty {
            let children = Set(nodes.flatMap { $0.children ?? [] })
            roots = nodes.indices.filter { !children.contains($0) }
        }
        var stack: [(Int, simd_float4x4)] = roots.map { ($0, matrix_identity_float4x4) }
        var visited = Set<Int>()
        while let (ni, parent) = stack.popLast() {
            guard ni < nodes.count, visited.insert(ni).inserted else { continue }
            let n = nodes[ni]
            let world = parent * localMatrix(n)
            for c in n.children ?? [] { stack.append((c, world)) }
            guard let mi = n.mesh, let mesh = doc.meshes?[mi] else { continue }
            let normalM = world.upperLeft.inverse.transpose
            for p in mesh.primitives {
                guard let pa = p.attributes["POSITION"] else { continue }
                var pos = reader.vec3(pa)
                for i in pos.indices {
                    let v = world * SIMD4(pos[i], 1)
                    pos[i] = SIMD3(v.x, v.y, v.z)
                    bmin = simd_min(bmin, pos[i]); bmax = simd_max(bmax, pos[i])
                }
                var nor = p.attributes["NORMAL"].map { reader.vec3($0) }
                if nor != nil { for i in nor!.indices { nor![i] = simd_normalize(normalM * nor![i]) } }
                // glTF → USD: flipped v
                let uv = p.attributes["TEXCOORD_0"].map { reader.vec2($0).map { SIMD2($0.x, 1 - $0.y) } }
                let idx = p.indices.map { reader.indices($0) }
                let mode = p.mode ?? 4
                verts += pos.count
                if mode == 4 { tris += (idx?.count ?? pos.count) / 3 } else if mode == 0 { points += pos.count }
                prims.append(
                    .init(positions: pos, normals: nor, uvs: uv, indices: idx, mode: mode, material: p.material))
            }
        }
        if prims.isEmpty { throw GLBError.unsupported("no geometry") }
        return LoadedModelData(
            prims: prims, materials: mats, boundsMin: bmin, boundsMax: bmax,
            vertexCount: verts, triangleCount: tris, pointCount: points)
    }

    private static func localMatrix(_ n: GLTFDoc.Node) -> simd_float4x4 {
        if let m = n.matrix, m.count == 16 {
            return simd_float4x4(
                columns: (
                    SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
                ))
        }
        var t = matrix_identity_float4x4
        if let tr = n.translation, tr.count == 3 { t.columns.3 = SIMD4(tr[0], tr[1], tr[2], 1) }
        var r = matrix_identity_float4x4
        if let q = n.rotation, q.count == 4 { r = simd_matrix4x4(simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])) }
        var s = matrix_identity_float4x4
        if let sc = n.scale, sc.count == 3 { s = simd_float4x4(diagonal: SIMD4(sc[0], sc[1], sc[2], 1)) }
        return t * r * s
    }

    /// Extracts one channel (0=R, 1=G, 2=B) as a greyscale image.
    private static func channel(_ img: CGImage, _ c: Int) -> CGImage? {
        let f = CIFilter.colorMatrix()
        f.inputImage = CIImage(cgImage: img)
        let v = CIVector(x: c == 0 ? 1 : 0, y: c == 1 ? 1 : 0, z: c == 2 ? 1 : 0, w: 0)
        f.rVector = v; f.gVector = v; f.bVector = v
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let out = f.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }
}

private extension simd_float4x4 {
    var upperLeft: simd_float3x3 {
        simd_float3x3(
            SIMD3(columns.0.x, columns.0.y, columns.0.z),
            SIMD3(columns.1.x, columns.1.y, columns.1.z),
            SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }
}

private struct AccessorReader {
    let doc: GLTFDoc
    let bin: Data

    private func components(_ type: String) -> Int {
        ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type] ?? 1
    }

    /// Reads an accessor as floats (de-normalizing normalized integers).
    func floats(_ index: Int, want: Int) -> [Float] {
        guard let a = doc.accessors?[index] else { return [] }
        let comps = components(a.type)
        var out = [Float](repeating: 0, count: a.count * want)
        guard let bvi = a.bufferView, let bv = doc.bufferViews?[bvi] else { return out }
        let csize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][a.componentType] ?? 4
        let stride = bv.byteStride ?? comps * csize
        let base = (bv.byteOffset ?? 0) + (a.byteOffset ?? 0)
        let norm = a.normalized ?? false
        bin.withUnsafeBytes { raw in
            for i in 0..<a.count {
                let e = base + i * stride
                for k in 0..<min(comps, want) {
                    let o = e + k * csize
                    let v: Float
                    switch a.componentType {
                    case 5126: v = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                    case 5120:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int8.self))
                        v = norm ? max(x / 127, -1) : x
                    case 5121:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self)); v = norm ? x / 255 : x
                    case 5122:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self))
                        v = norm ? max(x / 32767, -1) : x
                    case 5123:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)); v = norm ? x / 65535 : x
                    default: v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    }
                    out[i * want + k] = v
                }
            }
        }
        return out
    }

    func vec3(_ i: Int) -> [SIMD3<Float>] {
        let f = floats(i, want: 3)
        return (0..<(f.count / 3)).map { SIMD3(f[$0 * 3], f[$0 * 3 + 1], f[$0 * 3 + 2]) }
    }
    func vec2(_ i: Int) -> [SIMD2<Float>] {
        let f = floats(i, want: 2)
        return (0..<(f.count / 2)).map { SIMD2(f[$0 * 2], f[$0 * 2 + 1]) }
    }
    func indices(_ index: Int) -> [UInt32] {
        guard let a = doc.accessors?[index], let bvi = a.bufferView, let bv = doc.bufferViews?[bvi] else { return [] }
        let base = (bv.byteOffset ?? 0) + (a.byteOffset ?? 0)
        return bin.withUnsafeBytes { raw in
            (0..<a.count).map { i -> UInt32 in
                switch a.componentType {
                case 5121: UInt32(raw.loadUnaligned(fromByteOffset: base + i, as: UInt8.self))
                case 5123: UInt32(raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self))
                default: raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                }
            }
        }
    }
}
