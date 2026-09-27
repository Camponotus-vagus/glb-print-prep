import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 3D previews (RealityKit)

/// Lightweight thumbnail: loads the decimated copy (~50k triangles) and spins it
/// (still when Reduce Motion is on).
struct ModelThumbnail: View {
    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failed: String?
    @State private var loaded = false

    var body: some View {
        ZStack {
            RealityView { content in
                do {
                    let data = try await GLBLoader.load(url)
                    let model = try await SceneBuilder.makeEntity(data)
                    let scene = Entity()
                    let pivot = Entity()
                    pivot.addChild(model)
                    pivot.orientation = simd_quatf(angle: -0.5, axis: [0, 1, 0])
                    if !reduceMotion { pivot.components.set(SpinComponent(radiansPerSecond: 0.45)) }
                    scene.addChild(pivot)
                    let cam = PerspectiveCamera()
                    cam.camera.fieldOfViewInDegrees = 34
                    cam.look(at: [0, 0, 0], from: [0, 0.42, 1.95], relativeTo: nil)
                    scene.addChild(cam)
                    await SceneBuilder.addLighting(to: scene, model: pivot)
                    content.add(scene)
                    loaded = true
                } catch {
                    failed = error.localizedDescription
                }
            }
            .background(
                LinearGradient(colors: [Color(white: 0.93), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
            if !loaded && failed == nil { ProgressView().controlSize(.small) }
            if let failed {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).help(failed)
            }
        }
    }
}

/// Full viewer: the model fills the window (under the title bar too); controls live in the
/// system toolbar, which is already Liquid Glass — no custom glass on top.
struct ModelViewerWindow: View {
    let target: ViewerTarget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var info: LoadedModelData?
    @State private var error: String?
    @State private var loading = true
    @State private var yaw: Float = -0.5
    @State private var pitch: Float = 0.2
    @State private var dragBase: (Float, Float)?
    @State private var distance: Float = defaultDistance
    @State private var zoomBase: Float?
    @State private var autoRotate = true
    private static let defaultDistance: Float = 2.35

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            RealityView { content in
                do {
                    let data = try await GLBLoader.load(target.url)
                    let model = try await SceneBuilder.makeEntity(data)
                    let scene = Entity()
                    let pivot = Entity(); pivot.name = "pivot"
                    let spinner = Entity(); spinner.name = "spinner"
                    spinner.addChild(model)
                    pivot.addChild(spinner)
                    scene.addChild(pivot)
                    let cam = PerspectiveCamera(); cam.name = "camera"
                    cam.camera.fieldOfViewInDegrees = 36
                    scene.addChild(cam)
                    await SceneBuilder.addLighting(to: scene, model: pivot)
                    content.add(scene)
                    info = data
                } catch {
                    self.error = error.localizedDescription
                }
                loading = false
            } update: { content in
                guard let scene = content.entities.first,
                    let pivot = scene.findEntity(named: "pivot"),
                    let spinner = scene.findEntity(named: "spinner"),
                    let cam = scene.findEntity(named: "camera")
                else { return }
                pivot.orientation =
                    simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
                cam.look(at: .zero, from: [0, 0, distance], relativeTo: nil)
                if autoRotate {
                    if spinner.components[SpinComponent.self] == nil {
                        spinner.components.set(SpinComponent(radiansPerSecond: 0.35))
                    }
                } else {
                    spinner.components.remove(SpinComponent.self)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let base = dragBase ?? (yaw, pitch)
                        dragBase = base
                        yaw = base.0 + Float(v.translation.width) * 0.01
                        pitch = max(-1.4, min(1.4, base.1 + Float(v.translation.height) * 0.01))
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = zoomBase ?? distance
                        zoomBase = base
                        distance = max(0.6, min(8, base / Float(v.magnification)))
                    }
                    .onEnded { _ in zoomBase = nil }
            )
            .accessibilityLabel("3D model. Drag to rotate, pinch to zoom.")

            if loading {
                ProgressView("Loading the full model…")
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let error {
                ContentUnavailableView("Preview Unavailable", systemImage: "eye.slash", description: Text(error))
            }
        }
        .ignoresSafeArea()  // full-window content, under the glass toolbar
        .navigationTitle(target.title)
        .navigationSubtitle(info.map(statsText) ?? "")
        .onAppear { autoRotate = !reduceMotion }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $autoRotate) { Label("Auto-Rotate", systemImage: "rotate.3d") }
                    .help("Auto-rotate")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    distance = min(8, distance * 1.25)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                Button {
                    distance = max(0.6, distance / 1.25)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    yaw = -0.5; pitch = 0.2; distance = Self.defaultDistance
                } label: {
                    Label("Reset View", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help("Reset the view (⌘0)")
            }
        }
    }

    private func statsText(_ d: LoadedModelData) -> String {
        var p = ["\(d.vertexCount.formatted()) vertices"]
        if d.triangleCount > 0 { p.append("\(d.triangleCount.formatted()) triangles") }
        if d.pointCount > 0 { p.append("\(d.pointCount.formatted()) points") }
        return p.joined(separator: " · ")
    }
}

// MARK: - Utilities

func fmt(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
