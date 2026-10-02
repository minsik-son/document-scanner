import SwiftUI
import ARKit
import SceneKit

enum MeshExport {
    static func obj(vertices:[SIMD3<Float>], faces:[[Int]], offset:Int = 0) throws -> String {
        guard vertices.count <= 500000,faces.count <= 1000000,vertices.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),faces.allSatisfy({$0.count == 3 && $0.allSatisfy { vertices.indices.contains($0) }}) else { throw ScannerError.message("The mesh is too large or invalid.") }
        return vertices.map { "v \($0.x) \($0.y) \($0.z)" }.joined(separator:"\n") + "\n" + faces.map { "f \($0[0]+1+offset) \($0[1]+1+offset) \($0[2]+1+offset)" }.joined(separator:"\n") + "\n"
    }
}
@MainActor final class SpatialCapture: NSObject,ObservableObject,ARSessionDelegate {
    @Published var message = "Move slowly to find surfaces."
    @Published var distances:[Float] = []
    @Published var meshCount = 0
    @Published var running = false
    var view:ARSCNView?
    var meshes:[UUID:ARMeshAnchor] = [:]
    var points:[SIMD3<Float>] = []
    var markers:[SCNNode] = []
    let meshMode:Bool
    init(meshMode:Bool) { self.meshMode = meshMode }
    var supported:Bool { meshMode ? ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) : ARWorldTrackingConfiguration.isSupported }
    func start() {
        guard supported,let view else { return }
        let config = ARWorldTrackingConfiguration();config.planeDetection = [.horizontal,.vertical]
        if meshMode { config.sceneReconstruction = .mesh }
        view.session.delegate = self;view.session.delegateQueue = .main
        meshes = [:];meshCount = 0;clear();view.session.run(config,options:[.resetTracking,.removeExistingAnchors]);running = true
        message = meshMode ? "Walk around the object slowly. Stop before exporting." : "Tap a start point, then an end point on a surface."
    }
    func stop() { view?.session.pause();running = false }
    func clear() { distances = [];points = [];markers.forEach { $0.removeFromParentNode() };markers = [] }
    @objc func tap(_ recognizer:UITapGestureRecognizer) {
        guard running,!meshMode,let view,let frame = view.session.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else { message = "Move slowly until tracking is stable.";return }
        guard let query = view.raycastQuery(from:recognizer.location(in:view),allowing:.estimatedPlane,alignment:.any),let result = view.session.raycast(query).first else { message = "No surface found. Try a textured, well-lit surface.";return }
        let t = result.worldTransform.columns.3,p = SIMD3<Float>(t.x,t.y,t.z)
        let node = SCNNode(geometry:SCNSphere(radius:0.004));node.geometry?.firstMaterial?.diffuse.contents = UIColor.systemBlue;node.simdPosition = p;view.scene.rootNode.addChildNode(node);markers.append(node)
        points.append(p)
        if points.count == 2 { let distance = simd_distance(points[0],points[1]);distances.append(distance);message = String(format:"%.1f cm · tap the next start point",distance*100);points = [] }
        else { message = "Start marked. Tap the end point." }
    }
    nonisolated func session(_ session:ARSession,didAdd anchors:[ARAnchor]) { Task { @MainActor in self.accept(anchors) } }
    nonisolated func session(_ session:ARSession,didUpdate anchors:[ARAnchor]) { Task { @MainActor in self.accept(anchors) } }
    nonisolated func session(_ session:ARSession,didRemove anchors:[ARAnchor]) { Task { @MainActor in for anchor in anchors { self.meshes.removeValue(forKey:anchor.identifier) };self.meshCount = self.meshes.count } }
    nonisolated func session(_ session:ARSession,didFailWithError error:Error) { Task { @MainActor in self.stop();self.message = error.localizedDescription } }
    nonisolated func sessionWasInterrupted(_ session:ARSession) { Task { @MainActor in self.stop();self.message = "Capture interrupted. Start a new scan." } }
    func accept(_ anchors:[ARAnchor]) { guard running,meshMode else { return };for case let anchor as ARMeshAnchor in anchors { meshes[anchor.identifier] = anchor };meshCount = meshes.count; if meshes.values.reduce(0,{$0+$1.geometry.vertices.count}) > 500000 { stop();message = "Mesh limit reached. Export or start a smaller scan." } }
    func exportMesh() throws -> ExportedFiles {
        guard !running,!meshes.isEmpty else { throw ScannerError.message("Capture surfaces and stop the scan first.") }
        var text = "# Local AR mesh, coordinates in meters. No color texture.\n", offset = 0
        for anchor in meshes.values.sorted(by:{$0.identifier.uuidString < $1.identifier.uuidString}) {
            let geo = anchor.geometry,source = geo.vertices
            guard offset+source.count <= 500000 else { throw ScannerError.message("Scan a smaller area; this mesh exceeds the export limit.") }
            var vertices:[SIMD3<Float>] = []
            for i in 0..<source.count {
                let pointer = source.buffer.contents().advanced(by:source.offset+i*source.stride).assumingMemoryBound(to:Float.self)
                let p = SIMD3<Float>(pointer[0],pointer[1],pointer[2])
                let world = anchor.transform*SIMD4<Float>(p,1);vertices.append(SIMD3(world.x,world.y,world.z))
            }
            let element = geo.faces;var faces:[[Int]] = []
            guard element.indexCountPerPrimitive == 3 else { continue }
            for i in 0..<element.count {
                faces.append((0..<3).map { j in let address = element.buffer.contents().advanced(by:(i*3+j)*element.bytesPerIndex);return element.bytesPerIndex == 2 ? Int(address.load(as:UInt16.self)) : Int(address.load(as:UInt32.self)) })
            }
            text += try MeshExport.obj(vertices:vertices,faces:faces,offset:offset);offset += vertices.count
        }
        return try ExportFiles.write([("Scan.obj",Data(text.utf8))])
    }
}
struct SpatialCamera:UIViewRepresentable {
    @ObservedObject var capture:SpatialCapture
    func makeUIView(context:Context) -> ARSCNView { let view = ARSCNView();view.scene = SCNScene();view.debugOptions = [.showFeaturePoints];capture.view = view;view.addGestureRecognizer(UITapGestureRecognizer(target:capture,action:#selector(SpatialCapture.tap(_:))));return view }
    func updateUIView(_ uiView:ARSCNView,context:Context) {}
    static func dismantleUIView(_ uiView:ARSCNView,coordinator:()) { uiView.session.pause() }
}
struct SpatialToolsView:View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var capture:SpatialCapture
    @State private var files:ExportedFiles?
    @State private var share = false
    init(mesh:Bool) { _capture = StateObject(wrappedValue:SpatialCapture(meshMode:mesh)) }
    var body:some View {
        VStack(spacing:16) {
            if capture.supported {
                SpatialCamera(capture:capture).clipShape(RoundedRectangle(cornerRadius:20)).overlay(alignment:.top) { Text(capture.meshMode ? "\(capture.meshCount) surface sections" : "Tap two surface points").padding(10).background(.ultraThinMaterial,in:Capsule()).padding() }
                Text(capture.message).font(.subheadline)
                if !capture.meshMode { ScrollView(.horizontal) { HStack { ForEach(Array(capture.distances.enumerated()),id:\.offset) { i,d in Text(String(format:"%d: %.1f cm / %.2f in",i+1,d*100,d/0.0254)).padding(8) } } }.frame(height:44) }
                HStack { Button(capture.running ? "Stop" : "Start new capture") { capture.running ? capture.stop() : capture.start() }.buttonStyle(.borderedProminent)
                    Button("Export") { do { capture.stop();if let files { ExportFiles.remove(files.directory) };files = capture.meshMode ? try capture.exportMesh() : try ExportFiles.write([("Measurements.csv",Data(("Measurement,Metres\n"+capture.distances.enumerated().map { "\($0.offset+1),\($0.element)" }.joined(separator:"\n")).utf8))]);share = true } catch { capture.message = error.localizedDescription } }.disabled(capture.meshMode ? capture.meshCount == 0 : capture.distances.isEmpty)
                    if !capture.meshMode { Button("Clear") { capture.clear() } }
                }
                Text(capture.meshMode ? "LiDAR surface mesh in OBJ format. No photo texture or hidden-surface reconstruction." : "Approximate AR measurements. Check with a physical ruler when accuracy matters.").font(.footnote).foregroundStyle(.secondary)
            } else { ContentUnavailableView(capture.meshMode ? "LiDAR required" : "AR tracking unavailable",systemImage:"viewfinder",description:Text(capture.meshMode ? "3D scanning requires an iPhone with supported LiDAR hardware." : "Open this tool on an ARKit-compatible iPhone.")) }
        }.padding().navigationTitle(capture.meshMode ? "3D scan" : "Measure").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$share) { if let files { ShareSheet(items:files.urls) } }
            .onDisappear { capture.stop();if let files { ExportFiles.remove(files.directory) } }
    }
}
