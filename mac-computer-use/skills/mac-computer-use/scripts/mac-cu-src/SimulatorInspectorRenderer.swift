import AppKit
import MetalKit
import ImageIO
import UniformTypeIdentifiers
import simd

final class InspectorSceneView: MTKView {
    var onPick: (SIMD2<Float>) -> Void = { _ in }
    var onOrbit: (Float, Float) -> Void = { _, _ in }
    var onZoom: (Float) -> Void = { _ in }
    private var dragged = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { dragged = false; window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { dragged = true; onOrbit(Float(event.deltaX)*0.01, Float(event.deltaY)*0.01) }
    override func mouseUp(with event: NSEvent) {
        if !dragged { let p = convert(event.locationInWindow, from: nil); onPick(SIMD2(Float(p.x), Float(p.y))) }
    }
    override func scrollWheel(with event: NSEvent) { onZoom(Float(event.scrollingDeltaY)*0.01) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onOrbit(-0.1,0)
        case 124: onOrbit(0.1,0)
        case 125: onOrbit(0,0.1)
        case 126: onOrbit(0,-0.1)
        default: super.keyDown(with: event)
        }
    }
}
final class SimulatorInspectorRenderer: NSObject, MTKViewDelegate {
    struct Vertex { var position: SIMD4<Float>; var uv: SIMD2<Float> }
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private weak var view: MTKView?
    private var textures: [String: MTLTexture] = [:]
    var cachedTextureCount: Int { textures.count }
    private(set) var textureFailures: [String: String] = [:]
    private var snapshot: SimulatorInspectorSnapshot?
    var camera = InspectorCamera()
    var selection: String?
    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw InspectorFailure.invalid("3D unavailable: Metal device/queue") }
        self.queue = queue; self.view = view
        view.device = device; view.colorPixelFormat = .bgra8Unorm
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p; float2 uv; };
        struct O { float4 p [[position]]; float2 uv; };
        vertex O vertex_main(uint i [[vertex_id]], const device V *v [[buffer(0)]]) { O o; o.p=v[i].p; o.uv=v[i].uv; return o; }
        fragment float4 fragment_main(O in [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear); return t.sample(s,in.uv);
        }
        fragment float4 outline_main(O in [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let d = MTLRenderPipelineDescriptor(); d.vertexFunction = library.makeFunction(name: "vertex_main"); d.fragmentFunction = library.makeFunction(name: "fragment_main")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one; d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha; d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        d.fragmentFunction = library.makeFunction(name: "outline_main")
        outline = try device.makeRenderPipelineState(descriptor: d)
        super.init()
        view.isPaused = true; view.enableSetNeedsDisplay = true; view.delegate = self
        view.clearColor = MTLClearColorMake(0.08,0.09,0.11,1)
        view.setAccessibilityLabel("뷰 3D 장면. 방향키 회전, 트랙패드 확대")
    }
    private let outline: MTLRenderPipelineState
    func releaseCapture() { snapshot = nil; textures.removeAll(); textureFailures.removeAll(); selection = nil; view?.needsDisplay = true }
    func replace(_ snapshot: SimulatorInspectorSnapshot) {
        releaseCapture(); self.snapshot = snapshot
        guard let device = view?.device else { return }
        for a in snapshot.assets.values where snapshot.paintsTexture(a.nodeID) {
            do { textures[a.id] = try Self.texture(a, device: device) }
            catch { textureFailures[a.id] = error.localizedDescription }
        }
        view?.needsDisplay = true
    }
    private static func texture(_ a: InspectorAsset, device: MTLDevice) throws -> MTLTexture {
        // Model validates all envelope/aggregate budgets before ImageIO is reached.
        guard let source = CGImageSourceCreateWithData(a.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == a.width, properties[kCGImagePropertyPixelHeight] as? Int == a.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == a.width, image.height == a.height else { throw InspectorFailure.invalid("PNG decode/dimension mismatch") }
        let count = a.width * a.height * 4
        var pixels = [UInt8](repeating: 0, count: count)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Drawing a CGImage preserves its raw row order. UV (0,0) samples row zero;
            // a Quartz coordinate flip here would invert the PNG's top and bottom.
            c.draw(image, in: CGRect(x: 0, y: 0, width: a.width, height: a.height)); return true
        }
        guard ok else { throw InspectorFailure.invalid("RGBA allocation failed") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: a.width, height: a.height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw InspectorFailure.invalid("GPU texture allocation failed") }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,a.width,a.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: a.width*4) }
        return texture
    }
    func candidates(at point: SIMD2<Float>) -> [String] {
        guard let view, let s = snapshot, view.bounds.width > 0, view.bounds.height > 0 else { return [] }
        let size = SIMD2(Float(view.bounds.width),Float(view.bounds.height)), nodes = s.order.compactMap { s.nodes[$0] }
        let m = camera.matrix(nodes: nodes, aspect: size.x/size.y)
        return camera.ordered(nodes, matrix: m).reversed().filter { InspectorCamera.contains(point, polygon: camera.projected($0, matrix: m, size: size)) }.map(\.id)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }
    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeFrame(in: encoder, pixelSize: view.drawableSize)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    /// Same frame path for the displayed drawable and bounded offscreen GPU verification.
    func encodeFrame(in encoder: MTLRenderCommandEncoder, pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let nodes = snapshot.map { s in s.order.compactMap { s.nodes[$0] } } ?? [], m = camera.matrix(nodes: nodes, aspect: Float(pixelSize.width/pixelSize.height))
        encoder.setCullMode(.none)
        // Painter ordering with no depth writes preserves transparent texels and allows the rear quad through.
        for n in camera.ordered(nodes, matrix: m) where n.corners.count == 4 {
            let p = camera.clipCorners(n, matrix: m), uv: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
            if snapshot?.paintsTexture(n.id) == true, let id = n.assetID, let texture = textures[id] {
                let vertices = [0,1,2,0,2,3].map { Vertex(position: p[$0], uv: uv[$0]) }
                encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
                vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            if n.id == selection || (snapshot?.paintsTexture(n.id) == true && (n.assetID == nil || textures[n.assetID ?? ""] == nil)) {
                let vertices = [0,1,2,3,0].map { Vertex(position: p[$0], uv: uv[$0]) }
                var color = n.id == selection ? SIMD4<Float>(1,0.8,0.2,1) : SIMD4<Float>(0.6,0.65,0.75,1)
                encoder.setRenderPipelineState(outline); encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: 5)
            }
        }
    }
}
