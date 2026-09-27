import AppKit
import CoreGraphics
import GLBPrintPrepCore
import RealityKit
import simd

// MARK: - RealityKit scene construction

@MainActor
enum SceneBuilder {
    /// Model entity, centred on the origin and scaled into a unit cube.
    static func makeEntity(_ m: LoadedModelData) async throws -> Entity {
        let root = Entity()
        let model = Entity()
        root.addChild(model)

        var cache: [Int: RealityKit.Material] = [:]
        let diag = simd_length(m.boundsMax - m.boundsMin)

        for (pi, p) in m.prims.enumerated() {
            let entity: ModelEntity
            if p.mode == 0 {
                entity = try await pointCloud(p, radius: diag * 0.0022)
            } else if p.mode == 4 {
                var d = MeshDescriptor(name: "prim\(pi)")
                d.positions = MeshBuffers.Positions(p.positions)
                d.normals = MeshBuffers.Normals(p.normals ?? computeNormals(p))
                if let uv = p.uvs { d.textureCoordinates = MeshBuffers.TextureCoordinates(uv) }
                d.primitives = .triangles(p.indices ?? Array(0..<UInt32(p.positions.count)))
                let mesh = try await MeshResource(from: [d])
                let mat: RealityKit.Material
                if let mi = p.material, mi < m.materials.count {
                    if let c = cache[mi] { mat = c } else { mat = try await material(m.materials[mi]); cache[mi] = mat }
                } else {
                    var pbr = PhysicallyBasedMaterial()
                    pbr.baseColor = .init(tint: .init(white: 0.8, alpha: 1))
                    mat = pbr
                }
                entity = ModelEntity(mesh: mesh, materials: [mat])
            } else {
                continue
            }  // lines: not shown
            model.addChild(entity)
        }

        let center = (m.boundsMin + m.boundsMax) / 2
        let extent = max((m.boundsMax - m.boundsMin).max(), 1e-6)
        let s = 1 / extent
        model.scale = SIMD3(repeating: s)
        model.position = -center * s
        return root
    }

    private static func texture(_ img: SendableImage?, _ semantic: TextureResource.Semantic) async throws
        -> MaterialParameters.Texture?
    {
        guard let img else { return nil }
        let res = try await TextureResource(image: img.cg, options: .init(semantic: semantic))
        return .init(res)
    }

    private static func material(_ m: LoadedModelData.Mat) async throws -> RealityKit.Material {
        var pbr = PhysicallyBasedMaterial()
        let c = m.baseColor
        pbr.baseColor = .init(
            tint: NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1),
            texture: try await texture(m.baseTex, .color))
        pbr.metallic = .init(scale: m.metallic, texture: try await texture(m.metalTex, .raw))
        pbr.roughness = .init(scale: m.roughness, texture: try await texture(m.roughTex, .raw))
        if let n = try await texture(m.normalTex, .normal) { pbr.normal = .init(texture: n) }
        if m.emissiveTex != nil || m.emissive != .zero {
            pbr.emissiveColor = .init(
                color: NSColor(
                    srgbRed: CGFloat(m.emissive.x), green: CGFloat(m.emissive.y), blue: CGFloat(m.emissive.z), alpha: 1),
                texture: try await texture(m.emissiveTex, .color))
            pbr.emissiveIntensity = 1
        }
        if m.doubleSided { pbr.faceCulling = .none }
        if m.blend { pbr.blending = .transparent(opacity: .init(floatLiteral: c.w)) }
        return pbr
    }

    /// RealityKit has no point primitive: every point becomes a small octahedron.
    private static func pointCloud(_ p: LoadedModelData.Prim, radius r: Float) async throws -> ModelEntity {
        let dirs: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        let faces: [(UInt32, UInt32, UInt32)] = [
            (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5),
        ]
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        pos.reserveCapacity(p.positions.count * 6)
        nor.reserveCapacity(p.positions.count * 6)
        idx.reserveCapacity(p.positions.count * 24)
        for (i, c) in p.positions.enumerated() {
            let b = UInt32(i * 6)
            for d in dirs { pos.append(c + d * r); nor.append(d) }
            for f in faces { idx.append(contentsOf: [b + f.0, b + f.1, b + f.2]) }
        }
        var d = MeshDescriptor(name: "points")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nor)
        d.primitives = .triangles(idx)
        let mesh = try await MeshResource(from: [d])
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.86, alpha: 1))
        mat.roughness = .init(floatLiteral: 0.55)
        mat.metallic = .init(floatLiteral: 0)
        return ModelEntity(mesh: mesh, materials: [mat])
    }

    private static func computeNormals(_ p: LoadedModelData.Prim) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: p.positions.count)
        let idx = p.indices ?? Array(0..<UInt32(p.positions.count))
        for t in stride(from: 0, to: idx.count - 2, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = simd_cross(p.positions[b] - p.positions[a], p.positions[c] - p.positions[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        return n.map { simd_length($0) > 0 ? simd_normalize($0) : [0, 1, 0] }
    }

    // MARK: lighting

    private static var cachedEnvironment: EnvironmentResource?

    /// Procedural "studio" environment (equirectangular) for image-based lighting of PBR materials.
    static func environment() async throws -> EnvironmentResource {
        if let e = cachedEnvironment { return e }
        let w = 512, h = 256
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [
                CGColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1),
                CGColor(srgbRed: 0.72, green: 0.76, blue: 0.82, alpha: 1),
                CGColor(srgbRed: 0.30, green: 0.31, blue: 0.34, alpha: 1),
                CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
            ] as CFArray, locations: [0, 0.42, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        // two bright "softboxes"
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 90, y: 170, width: 90, height: 45))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.92, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 330, y: 160, width: 70, height: 38))
        let env = try await EnvironmentResource(equirectangular: ctx.makeImage()!)
        cachedEnvironment = env
        return env
    }

    /// Adds image-based and directional light to `root` and connects them to every model.
    static func addLighting(to root: Entity, model: Entity) async {
        if let env = try? await environment() {
            let ibl = Entity()
            ibl.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 0.6))
            root.addChild(ibl)
            model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
            for e in model.descendants { e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl)) }
        }
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.look(at: .zero, from: [1.2, 2, 1.5], relativeTo: nil)
        root.addChild(sun)
    }
}

extension Entity {
    var descendants: [Entity] {
        children.flatMap { [$0] + $0.descendants }
    }
}

// MARK: - Auto-rotation (ECS)

struct SpinComponent: Component {
    var radiansPerSecond: Float = 0.5
}

struct SpinSystem: System {
    static let query = EntityQuery(where: .has(SpinComponent.self))
    init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let s = e.components[SpinComponent.self] else { continue }
            e.transform.rotation =
                simd_quatf(angle: s.radiansPerSecond * Float(context.deltaTime), axis: [0, 1, 0]) * e.transform.rotation
        }
    }
}
