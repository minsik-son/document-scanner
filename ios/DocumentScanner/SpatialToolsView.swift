import SwiftUI
import ARKit
import SceneKit

enum MeshExport {
    static func obj(vertices:[SIMD3<Float>], faces:[[Int]], offset:Int = 0) throws -> String {
        guard vertices.count <= 500000,faces.count <= 1000000,vertices.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),faces.allSatisfy({$0.count == 3 && $0.allSatisfy { vertices.indices.contains($0) }}) else { throw ScannerError.message("The mesh is too large or invalid.") }
        return vertices.map { "v \($0.x) \($0.y) \($0.z)" }.joined(separator:"\n") + "\n" + faces.map { "f \($0[0]+1+offset) \($0[1]+1+offset) \($0[2]+1+offset)" }.joined(separator:"\n") + "\n"
    }
    /// World-space vertices and triangle indices of a mesh anchor.
    static func geometry(_ anchor: ARMeshAnchor) -> ([SIMD3<Float>], [[Int]]) {
        let geo = anchor.geometry, source = geo.vertices
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(source.count)
        for i in 0..<source.count {
            let pointer = source.buffer.contents().advanced(by: source.offset + i * source.stride).assumingMemoryBound(to: Float.self)
            let world = anchor.transform * SIMD4<Float>(pointer[0], pointer[1], pointer[2], 1)
            vertices.append(SIMD3(world.x, world.y, world.z))
        }
        let element = geo.faces
        guard element.indexCountPerPrimitive == 3 else { return (vertices, []) }
        var faces: [[Int]] = []
        faces.reserveCapacity(element.count)
        for i in 0..<element.count {
            faces.append((0..<3).map { j in
                let address = element.buffer.contents().advanced(by: (i * 3 + j) * element.bytesPerIndex)
                return element.bytesPerIndex == 2 ? Int(address.load(as: UInt16.self)) : Int(address.load(as: UInt32.self))
            })
        }
        return (vertices, faces)
    }
    /// SceneKit geometry for previews, in world space.
    static func scene(vertices: [SIMD3<Float>], faces: [[Int]]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let indices = faces.flatMap { $0.map { UInt32($0) } }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [source], elements: [element])
    }
}

// MARK: - Measure

enum MeasureUnit: String, CaseIterable { case cm, inch = "in"
    func text(_ meters: Float) -> String {
        self == .cm ? (meters >= 1 ? String(format: "%.2f m", meters) : String(format: "%.1f cm", meters * 100)) : String(format: "%.1f in", meters / 0.0254)
    }
}

@MainActor final class MeasureSession: NSObject, ObservableObject, ARSessionDelegate {
    struct Segment: Identifiable { let id = UUID(); let a: SIMD3<Float>; let b: SIMD3<Float>; var length: Float { simd_distance(a, b) } }
    @Published var hint = "Move your iPhone slowly to find a surface."
    @Published var segments: [Segment] = []
    @Published var start: SIMD3<Float>?
    @Published var aim: SIMD3<Float>?
    @Published var tracking = false
    @Published var projected: [UUID: (CGPoint, CGPoint)] = [:]
    @Published var liveLine: (CGPoint, CGPoint)?
    weak var view: ARSCNView?
    private var timer: Timer?
    var supported: Bool { ARWorldTrackingConfiguration.isSupported }
    func run() {
        guard supported, let view else { return }
        let config = ARWorldTrackingConfiguration(); config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        view.session.delegate = self
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func pause() { timer?.invalidate(); timer = nil; view?.session.pause() }
    private func tick() {
        guard let view, let frame = view.session.currentFrame else { return }
        if case .normal = frame.camera.trackingState { tracking = true } else { tracking = false }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let query = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any), let hit = view.session.raycast(query).first {
            let t = hit.worldTransform.columns.3
            aim = SIMD3(t.x, t.y, t.z)
        } else { aim = nil }
        hint = !tracking ? "Move your iPhone slowly to find a surface." : (aim == nil ? "Point the dot at a surface." : (start == nil ? "Aim at the start and tap +." : "Aim at the end and tap +."))
        func screen(_ p: SIMD3<Float>) -> CGPoint { let v = view.projectPoint(SCNVector3(p.x, p.y, p.z)); return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)) }
        var lines: [UUID: (CGPoint, CGPoint)] = [:]
        for s in segments { lines[s.id] = (screen(s.a), screen(s.b)) }
        projected = lines
        if let start, let aim { liveLine = (screen(start), screen(aim)) } else { liveLine = nil }
    }
    func addPoint() {
        guard let aim else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let start { segments.append(Segment(a: start, b: aim)); self.start = nil }
        else { start = aim }
    }
    func undo() { if start != nil { start = nil } else if !segments.isEmpty { segments.removeLast() } }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) { Task { @MainActor in self.hint = error.localizedDescription } }
}

struct MeasureARView: UIViewRepresentable {
    let session: MeasureSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(); view.scene = SCNScene(); view.automaticallyUpdatesLighting = true
        session.view = view; session.run(); return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) { uiView.session.pause() }
}

/// Measuring: aim the centre dot, tap + at each end. Live length while aiming.
struct MeasureToolView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var measuring = false
    @State private var results: [Float] = []
    @State private var unit = MeasureUnit.cm
    @State private var files: ExportedFiles?
    private var supported: Bool { ARWorldTrackingConfiguration.isSupported }
    var body: some View {
        ToolPage(title: results.isEmpty ? "Measure with the camera" : "Your measurements", subtitle: results.isEmpty ? "Aim at two points to measure the distance between them." : "Approximate. Check with a ruler when it matters.") {
            if results.isEmpty {
                ToolHero(art: .measure)
                VStack(alignment: .leading, spacing: 14) {
                    tip("iphone.gen3.radiowaves.left.and.right", "Move slowly until the dot sits on the surface.")
                    tip("plus.circle.fill", "Tap + at the start and again at the end.")
                    tip("sun.max.fill", "Good light and textured surfaces work best.")
                }
                if !supported {
                    ToastMessage(text: "AR tracking unavailable. Open this tool on an ARKit-compatible iPhone.", symbol: "exclamationmark.triangle.fill", tint: TK.orange)
                        .accessibilityIdentifier("measure-unsupported")
                }
            } else {
                Picker("Unit", selection: $unit) { ForEach(MeasureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { i, value in
                        HStack {
                            Text("Measurement \(i + 1)").font(.system(size: 16, weight: .medium)).foregroundStyle(TK.grey700)
                            Spacer()
                            Text(unit.text(value)).font(.system(size: 20, weight: .bold)).foregroundStyle(TK.grey900).monospacedDigit()
                        }.padding(.vertical, 14)
                        if i < results.count - 1 { Divider() }
                    }
                }
            }
        } actions: {
            if !results.isEmpty {
                Button("Share as spreadsheet") { share() }.buttonStyle(SecondaryCTAStyle())
            }
            Button(results.isEmpty ? "Start measuring" : "Measure again") { measuring = true }
                .buttonStyle(CTAButtonStyle()).disabled(!supported).accessibilityIdentifier("measure-start")
        }
        .navigationTitle("").fullScreenCover(isPresented: $measuring) {
            MeasureScreen(unit: $unit) { values in measuring = false; if !values.isEmpty { results = values } }
        }
        .sheet(item: $files) { files in ShareSheet(items: files.urls) { _, _ in ExportFiles.remove(files.directory) } }
    }
    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(TK.blue).frame(width: 40, height: 40).background(TK.blueSoft, in: Circle())
            Text(text).font(.system(size: 16)).foregroundStyle(TK.grey800)
        }
    }
    private func share() {
        let rows = results.enumerated().map { "\($0.offset + 1),\(String(format: "%.4f", $0.element)),\(String(format: "%.2f", $0.element * 100)),\(String(format: "%.2f", $0.element / 0.0254))" }
        files = try? ExportFiles.write([("Measurements.csv", Data(("Measurement,Metres,Centimetres,Inches\n" + rows.joined(separator: "\n")).utf8))])
    }
}

private struct MeasureScreen: View {
    @Binding var unit: MeasureUnit
    let done: ([Float]) -> Void
    @StateObject private var session = MeasureSession()
    var body: some View {
        ZStack {
            MeasureARView(session: session).ignoresSafeArea()
            Canvas { context, _ in
                for segment in session.segments {
                    guard let line = session.projected[segment.id] else { continue }
                    var path = Path(); path.move(to: line.0); path.addLine(to: line.1)
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    for p in [line.0, line.1] { context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white)) }
                }
                if let live = session.liveLine {
                    var path = Path(); path.move(to: live.0); path.addLine(to: live.1)
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
                    context.fill(Path(ellipseIn: CGRect(x: live.0.x - 6, y: live.0.y - 6, width: 12, height: 12)), with: .color(.white))
                }
            }.ignoresSafeArea().allowsHitTesting(false)
            ForEach(session.segments) { segment in
                if let line = session.projected[segment.id] {
                    label(unit.text(segment.length)).position(x: (line.0.x + line.1.x) / 2, y: (line.0.y + line.1.y) / 2 - 20)
                }
            }.ignoresSafeArea()
            // Reticle
            ZStack {
                Circle().strokeBorder(.white.opacity(session.aim == nil ? 0.5 : 1), lineWidth: 3).frame(width: 64, height: 64)
                Circle().fill(.white).frame(width: 8, height: 8)
            }.allowsHitTesting(false)
            if let start = session.start, let aim = session.aim {
                label(unit.text(simd_distance(start, aim)), large: true).offset(y: -64).allowsHitTesting(false)
            }
            VStack {
                HStack {
                    Button { session.pause(); done(session.segments.map(\.length)) } label: {
                        Text("Done").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 18).frame(height: 40).background(.black.opacity(0.45), in: Capsule())
                    }.accessibilityIdentifier("measure-done")
                    Spacer()
                    Picker("Unit", selection: $unit) { ForEach(MeasureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 110)
                }.padding(.horizontal, 20)
                Text(session.hint).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: Capsule()).padding(.top, 8)
                Spacer()
                HStack(spacing: 46) {
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 20, weight: .semibold)).frame(width: 54, height: 54).background(.black.opacity(0.45), in: Circle()) }
                        .disabled(session.start == nil && session.segments.isEmpty).accessibilityLabel("Undo")
                    Button { session.addPoint() } label: {
                        Image(systemName: "plus").font(.system(size: 34, weight: .bold)).foregroundStyle(TK.grey900)
                            .frame(width: 78, height: 78).background(.white, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 4).padding(-6))
                    }.disabled(session.aim == nil).opacity(session.aim == nil ? 0.5 : 1).accessibilityLabel(session.start == nil ? "Add start point" : "Add end point")
                    Text("\(session.segments.count)").font(.system(size: 18, weight: .bold)).frame(width: 54, height: 54).background(.black.opacity(0.45), in: Circle())
                        .accessibilityLabel("\(session.segments.count) measurements")
                }.padding(.bottom, 24)
            }.foregroundStyle(.white)
        }
        .statusBarHidden()
    }
    private func label(_ text: String, large: Bool = false) -> some View {
        Text(text).font(.system(size: large ? 20 : 15, weight: .bold)).foregroundStyle(TK.grey900).monospacedDigit()
            .padding(.horizontal, large ? 14 : 10).padding(.vertical, large ? 8 : 5).background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4)
    }
}

// MARK: - 3D scan

@MainActor final class MeshSession: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    @Published var sections = 0
    @Published var vertices = 0
    @Published var running = false
    @Published var hint = "Point at the object and move around it slowly."
    var meshes: [UUID: ARMeshAnchor] = [:]
    weak var view: ARSCNView?
    static var supported: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }
    func start() {
        guard Self.supported, let view else { return }
        let config = ARWorldTrackingConfiguration(); config.sceneReconstruction = .mesh
        config.environmentTexturing = .none
        view.session.delegate = self; view.delegate = self
        meshes = [:]; sections = 0; vertices = 0
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }
    func stop() { view?.session.pause(); running = false }
    nonisolated func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode(geometry: Self.wireframe(mesh))
        return node
    }
    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = Self.wireframe(mesh)
    }
    nonisolated private static func wireframe(_ anchor: ARMeshAnchor) -> SCNGeometry {
        let geo = anchor.geometry
        let vertices = SCNGeometrySource(buffer: geo.vertices.buffer, vertexFormat: geo.vertices.format, semantic: .vertex,
                                         vertexCount: geo.vertices.count, dataOffset: geo.vertices.offset, dataStride: geo.vertices.stride)
        let faces = geo.faces
        let data = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        let geometry = SCNGeometry(sources: [vertices], elements: [element])
        let material = SCNMaterial()
        material.fillMode = .lines
        material.diffuse.contents = UIColor(red: 0.09, green: 0.73, blue: 0.6, alpha: 0.9)
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { Task { @MainActor in self.accept(anchors) } }
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { Task { @MainActor in self.accept(anchors) } }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) { Task { @MainActor in self.stop(); self.hint = error.localizedDescription } }
    nonisolated func sessionWasInterrupted(_ session: ARSession) { Task { @MainActor in self.stop(); self.hint = "Scanning was interrupted. Start again." } }
    private func accept(_ anchors: [ARAnchor]) {
        guard running else { return }
        for case let anchor as ARMeshAnchor in anchors { meshes[anchor.identifier] = anchor }
        sections = meshes.count
        vertices = meshes.values.reduce(0) { $0 + $1.geometry.vertices.count }
        if vertices > 500000 { stop(); hint = "That's as much detail as one scan can hold. Review it now." }
    }
    /// Snapshot of the captured surfaces for preview and export.
    func capture() throws -> CapturedMesh {
        guard !meshes.isEmpty else { throw ScannerError.message("Nothing was captured yet. Move around the object slowly.") }
        var vertices: [SIMD3<Float>] = [], faces: [[Int]] = []
        for anchor in meshes.values.sorted(by: { $0.identifier.uuidString < $1.identifier.uuidString }) {
            let (v, f) = MeshExport.geometry(anchor)
            let offset = vertices.count
            guard offset + v.count <= 500000 else { break }
            vertices += v; faces += f.map { $0.map { $0 + offset } }
        }
        return CapturedMesh(vertices: vertices, faces: faces)
    }
}
struct CapturedMesh {
    let vertices: [SIMD3<Float>]
    let faces: [[Int]]
    func obj() throws -> ExportedFiles {
        let text = "# 3D scan made on iPhone. Coordinates in metres. No color texture.\n" + (try MeshExport.obj(vertices: vertices, faces: faces))
        return try ExportFiles.write([("3D scan.obj", Data(text.utf8))])
    }
}

struct MeshARView: UIViewRepresentable {
    let session: MeshSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(); view.scene = SCNScene(); view.automaticallyUpdatesLighting = true
        session.view = view; session.start(); return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) { uiView.session.pause() }
}

/// 3D scan: intro, live capture with a surface wireframe, then a turnable preview.
struct MeshToolView: View {
    @State private var scanning = false
    @State private var captured: CapturedMesh?
    @State private var files: ExportedFiles?
    @State private var problem: String?
    var body: some View {
        Group {
            if let captured { preview(captured) } else { intro }
        }
        .fullScreenCover(isPresented: $scanning) {
            MeshScanScreen { result in
                scanning = false
                switch result {
                case .some(.success(let mesh)): captured = mesh
                case .some(.failure(let error)): problem = error.localizedDescription
                case .none: break
                }
            }
        }
        .sheet(item: $files) { files in ShareSheet(items: files.urls) { _, _ in ExportFiles.remove(files.directory) } }
    }
    private var intro: some View {
        ToolPage(title: "Scan an object in 3D", subtitle: "Walk around it slowly. You'll get a 3D model to open in other apps.") {
            ToolHero(art: .mesh)
            if !MeshSession.supported {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LiDAR required").font(.system(size: 17, weight: .bold)).foregroundStyle(TK.grey900)
                    Text("3D scanning needs an iPhone Pro with a LiDAR sensor.").font(.system(size: 15)).foregroundStyle(TK.grey600)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(TK.orangeSoft, in: RoundedRectangle(cornerRadius: 18))
            }
            VStack(alignment: .leading, spacing: 14) {
                row("cube.transparent", "Works best for furniture, rooms and objects bigger than a shoebox.")
                row("figure.walk", "Move around the object once at an even, slow pace.")
                row("square.and.arrow.up", "Exports an OBJ model in real size. No photo texture.")
            }
            if let problem { ToastMessage(text: problem) }
        } actions: {
            Button("Start scanning") { problem = nil; scanning = true }.buttonStyle(CTAButtonStyle()).disabled(!MeshSession.supported).accessibilityIdentifier("mesh-start")
        }
    }
    private func preview(_ mesh: CapturedMesh) -> some View {
        ToolPage(title: "Your 3D scan", subtitle: "Drag to turn it. Pinch to zoom.", scrolls: false) {
            MeshPreview(mesh: mesh).frame(maxHeight: .infinity).background(TK.grey900, in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            Text("\(mesh.vertices.count.formatted()) points · \(mesh.faces.count.formatted()) faces").font(.system(size: 14, weight: .medium)).foregroundStyle(TK.grey500)
        } actions: {
            Button("Scan again") { captured = nil; scanning = true }.buttonStyle(SecondaryCTAStyle())
            Button("Share 3D model") { do { files = try mesh.obj() } catch { problem = error.localizedDescription } }.buttonStyle(CTAButtonStyle())
        }
    }
    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.teal).frame(width: 40, height: 40).background(TK.tealSoft, in: Circle())
            Text(text).font(.system(size: 16)).foregroundStyle(TK.grey800)
        }
    }
}

private struct MeshScanScreen: View {
    let done: (Result<CapturedMesh, Error>?) -> Void
    @StateObject private var session = MeshSession()
    var body: some View {
        ZStack {
            MeshARView(session: session).ignoresSafeArea()
            VStack {
                HStack {
                    Button { session.stop(); done(nil) } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle()) }
                        .accessibilityLabel("Cancel")
                    Spacer()
                    Text("\(session.sections) surfaces").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).frame(height: 36).background(.black.opacity(0.45), in: Capsule())
                }.padding(.horizontal, 20)
                Text(session.hint).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.45), in: Capsule()).padding(.top, 8)
                Spacer()
                Button {
                    session.stop()
                    do { done(.success(try session.capture())) } catch { done(.failure(error)) }
                } label: {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 5).frame(width: 82, height: 82)
                        RoundedRectangle(cornerRadius: 8).fill(TK.red).frame(width: 32, height: 32)
                    }
                }.accessibilityLabel("Finish scan").padding(.bottom, 12)
                Text("Finish").font(.system(size: 14, weight: .semibold)).padding(.bottom, 20)
            }.foregroundStyle(.white)
        }.statusBarHidden()
    }
}

private struct MeshPreview: UIViewRepresentable {
    let mesh: CapturedMesh
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.backgroundColor = .clear; view.allowsCameraControl = true; view.autoenablesDefaultLighting = true
        let scene = SCNScene()
        let geometry = MeshExport.scene(vertices: mesh.vertices, faces: mesh.faces)
        let material = SCNMaterial(); material.diffuse.contents = UIColor(white: 0.85, alpha: 1); material.isDoubleSided = true; material.lightingModel = .physicallyBased
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        let (minimum, maximum) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, (minimum.z + maximum.z) / 2)
        scene.rootNode.addChildNode(node)
        let camera = SCNNode(); camera.camera = SCNCamera()
        let span = max(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z, 0.2)
        camera.position = SCNVector3(0, 0, span * 1.8); scene.rootNode.addChildNode(camera)
        view.scene = scene; view.pointOfView = camera
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

/// Kept for callers that still name the old combined screen.
struct SpatialToolsView: View {
    let mesh: Bool
    var body: some View { if mesh { MeshToolView() } else { MeasureToolView() } }
}
