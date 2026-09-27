import GLBPrintPrepCore
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 3D previews (RealityKit)

/// Lightweight thumbnail: loads the decimated copy (~50k triangles) once and frames it to fit.
/// By default it turns only while the pointer is over it in an active window (Settings ▸ "Rotate
/// thumbnails continuously" makes it always turn; never with Reduce Motion):
/// a column of always-spinning RealityViews redraws every frame and makes other animations
/// in the window (e.g. the inspector) stutter.
struct ModelThumbnail: View {
    let url: URL
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var failed: String?
    @State private var loaded = false
    @State private var hovering = false

    private static let fov: Float = 30
    private static let elevation: Float = 0.3  // ≈ 17°, looking slightly down on the model

    private var spinning: Bool {
        loaded && (hovering || store.alwaysSpinThumbnails) && appearsActive && !reduceMotion
    }

    var body: some View {
        RealityView { content in
            // `make` runs once per view identity; later state changes only call `update`.
            do {
                let data = try await GLBLoader.load(url)
                let model = try await SceneBuilder.makeEntity(data)
                let scene = Entity()
                let pivot = Entity()
                pivot.name = "pivot"
                pivot.addChild(model)
                pivot.orientation = simd_quatf(angle: -0.5, axis: [0, 1, 0])
                scene.addChild(pivot)
                let cam = PerspectiveCamera()
                cam.camera.fieldOfViewInDegrees = Self.fov
                let t = tan(Self.fov / 2 * .pi / 180)  // square view: same tangent both ways
                let d = SceneBuilder.fittingDistance(
                    data, tanHalfWidth: t, tanHalfHeight: t, elevation: Self.elevation)
                cam.look(
                    at: .zero, from: [0, d * sin(Self.elevation), d * cos(Self.elevation)], relativeTo: nil)
                scene.addChild(cam)
                await SceneBuilder.addLighting(to: scene, model: pivot, exposure: 1.0)
                content.add(scene)
                loaded = true
            } catch {
                failed = error.localizedDescription
            }
        } update: { content in
            guard let pivot = content.entities.first?.findEntity(named: "pivot") else { return }
            if spinning {
                if pivot.components[SpinComponent.self] == nil {
                    pivot.components.set(SpinComponent(radiansPerSecond: 0.6))
                }
            } else if pivot.components[SpinComponent.self] != nil {
                pivot.components.remove(SpinComponent.self)
            }
        }
        .id(url)  // a new preview file gets a fresh scene
        // Same semantic fill as the queued/running/failed placeholders: adapts to dark mode and
        // doesn't flash when a card turns from running to done.
        .background(.quinary)
        .overlay {
            if let failed {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).help(failed)
            } else if !loaded {
                ProgressView().controlSize(.small)
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: url) {
            loaded = false
            failed = nil
        }
    }
}

/// Full viewer: the model fills the window (under the title bar too); controls live in the
/// system toolbar, which is already Liquid Glass, so no custom glass on top.
struct ModelViewerWindow: View {
    let target: ViewerTarget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var info: LoadedModelData?
    @State private var error: String?
    @State private var loading = true
    @State private var yaw: Float = Self.defaultYaw
    @State private var pitch: Float = Self.defaultPitch
    @State private var dragBase: (Float, Float)?
    @State private var fitDistance: Float = 2.35
    @State private var distance: Float = 2.35
    @State private var zoomBase: Float?
    @State private var autoRotate = true
    @State private var spinner: Entity?
    @State private var viewSize = CGSize(width: 900, height: 720)

    private static let defaultYaw: Float = -0.5
    private static let defaultPitch: Float = 0.2
    private static let fov: Float = 36  // vertical
    /// Height of the glass toolbar that overlaps the top of the full-window 3D view.
    private static let toolbarHeight: Float = 52

    private var tanHalfFOV: Float { tan(Self.fov / 2 * .pi / 180) }

    var body: some View {
        ZStack {
            // Dark "studio" backdrop in both appearances, like other 3D viewers: models read best on it.
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            RealityView { content in
                do {
                    let data = try await GLBLoader.load(target.url)
                    let model = try await SceneBuilder.makeEntity(data)
                    let scene = Entity()
                    let pivot = Entity()
                    pivot.name = "pivot"
                    let spinner = Entity()
                    spinner.name = "spinner"
                    spinner.addChild(model)
                    pivot.addChild(spinner)
                    scene.addChild(pivot)
                    let cam = PerspectiveCamera()
                    cam.name = "camera"
                    cam.camera.fieldOfViewInDegrees = Self.fov
                    scene.addChild(cam)
                    await SceneBuilder.addLighting(to: scene, model: pivot)
                    content.add(scene)
                    // Fit to the area below the toolbar.
                    let h = Float(max(viewSize.height, 1)), w = Float(max(viewSize.width, 1))
                    let fit = SceneBuilder.fittingDistance(
                        data, tanHalfWidth: tanHalfFOV * w / h,
                        tanHalfHeight: tanHalfFOV * max(h - Self.toolbarHeight, 1) / h,
                        elevation: Self.defaultPitch, margin: 1.12)
                    fitDistance = fit
                    distance = fit
                    self.spinner = spinner
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
                // Raise the camera by half the toolbar height so the model is centred in the visible area.
                let dy = distance * tanHalfFOV * Self.toolbarHeight / Float(max(viewSize.height, 1))
                cam.look(at: [0, dy, 0], from: [0, dy, distance], relativeTo: nil)
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
                        if dragBase == nil && autoRotate { autoRotate = false }  // the user takes over
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
                        distance = clampedDistance(base / Float(v.magnification))
                    }
                    .onEnded { _ in zoomBase = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetView() })
            .accessibilityLabel("3D model")
            .accessibilityHint("Drag to rotate, pinch to zoom, double-click to reset the view.")

            Group {
                if loading {
                    ProgressView("Loading the full model…").controlSize(.large)
                }
                if let error {
                    ContentUnavailableView("Preview Unavailable", systemImage: "eye.slash", description: Text(error))
                }
            }
            .environment(\.colorScheme, .dark)  // legible on the dark backdrop in Light Mode too
        }
        .ignoresSafeArea()  // full-window content, under the glass toolbar
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            viewSize = $0
        }
        .navigationTitle(target.title)
        .navigationSubtitle(info.map(statsText) ?? "")
        .onAppear { autoRotate = !reduceMotion }
        .onChange(of: reduceMotion) { _, on in
            if on { autoRotate = false }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $autoRotate) { Label("Auto-Rotate", systemImage: "rotate.3d") }
                    .help("Auto-Rotate")
                    .accessibilityIdentifier("viewer.autorotate")
                    .disabled(info == nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    distance = clampedDistance(distance * 1.25)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom Out (⌘−)")
                .accessibilityIdentifier("viewer.zoomOut")
                .disabled(info == nil)
                Button {
                    distance = clampedDistance(distance / 1.25)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)
                .help("Zoom In (⌘+)")
                .accessibilityIdentifier("viewer.zoomIn")
                .disabled(info == nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: resetView) {
                    Label("Reset View", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help("Reset View (⌘0), or double-click the model")
                .accessibilityIdentifier("viewer.reset")
                .disabled(info == nil)
            }
        }
    }

    /// Zoom range relative to the fitted distance, so small and large models behave the same.
    private func clampedDistance(_ d: Float) -> Float {
        max(fitDistance * 0.35, min(fitDistance * 4, d))
    }

    private func resetView() {
        yaw = Self.defaultYaw
        pitch = Self.defaultPitch
        distance = fitDistance
        spinner?.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])  // undo accumulated auto-rotation
    }

    private func statsText(_ d: LoadedModelData) -> String {
        var p: [String] = []
        if d.triangleCount > 0 {
            p.append("\(d.triangleCount.formatted()) triangles")
            p.append("\(d.vertexCount.formatted()) vertices")
        }
        // a pure point cloud has as many vertices as points: say it once
        if d.pointCount > 0 { p.append("\(d.pointCount.formatted()) points") }
        if p.isEmpty { p.append("\(d.vertexCount.formatted()) vertices") }
        return p.joined(separator: " · ")
    }
}

// MARK: - Utilities

func fmt(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
