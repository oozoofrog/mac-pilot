import AppKit
import MetalKit
import simd

@main struct InspectorMetalCheck {
    static func main() throws {
        guard Array(CommandLine.arguments.dropFirst()) == ["--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
        setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
        var checks = 0
        func check(_ ok: Bool, _ label: String) { guard ok else { fatalError(label) }; checks += 1; print("PASS \(label)") }
        let context = SimulatorInspectorContext(deviceID:"synthetic",displayID:"synthetic",targetID:"synthetic",targetLabel:"Synthetic GPU fixture",presentationRevision:1)
        let corners = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII="
        let clear = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DAAMIMMAYAKegD/QE6Y34AAAAASUVORK5CYII="
        let blue = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGNgYPj/H4KhDAA/0gf5tBJPzQAAAABJRU5ErkJggg=="
        func snapshot(_ images: [(String,String)]) throws -> SimulatorInspectorSnapshot {
            var assets: [String:Any] = [:], roots: [[String:Any]] = []
            for (id,png) in images {
                roots.append(["id":id,"className":"UIView","parentID":NSNull(),"children":[],"hidden":false,"alpha":1.0,"assetID":id,
                    "geometry":["coordinateSpace":"UIScreen.fixedCoordinateSpace points","corners":[[0.0,0.0],[200.0,0.0],[200.0,200.0],[0.0,200.0]]]])
                assets[id] = ["nodeID":id,"captureID":"capture","format":"png","encoding":"base64","pixelWidth":2,"pixelHeight":2,"data":png]
            }
            return try SimulatorInspectorSnapshot.parse(["captureID":"capture","capturedAt":"2026-11-09T00:00:00Z","roots":roots,"assets":assets],context:context)
        }
        let view = MTKView(frame:NSRect(x:0,y:0,width:256,height:256))
        let renderer = try SimulatorInspectorRenderer(view:view)
        renderer.camera.yaw = 0; renderer.camera.pitch = 0; renderer.camera.explosion = 0
        guard let device = view.device, let queue = device.makeCommandQueue() else { throw InspectorFailure.invalid("No GPU queue") }
        func render(_ snapshot: SimulatorInspectorSnapshot) throws -> [UInt8] {
            renderer.replace(snapshot)
            check(renderer.textureFailures.isEmpty,"real ImageIO decode and GPU texture creation")
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:256,height:256,mipmapped:false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
            guard let texture = device.makeTexture(descriptor:descriptor), let command = queue.makeCommandBuffer() else { throw InspectorFailure.invalid("No offscreen target") }
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { throw InspectorFailure.invalid("No encoder") }
            renderer.encodeFrame(in:encoder,pixelSize:CGSize(width:256,height:256)); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            check(command.status == .completed && command.error == nil,"production Metal frame completes")
            var bytes = [UInt8](repeating:0,count:256*256*4)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:256*4,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0) }
            return bytes
        }
        let s = try snapshot([("a",corners)]), pixels = try render(s)
        let nodes = s.order.compactMap { s.nodes[$0] }, matrix = renderer.camera.matrix(nodes:nodes,aspect:1)
        let polygon = renderer.camera.projected(nodes[0],matrix:matrix,size:SIMD2(256,256))
        func sample(_ bytes: [UInt8], _ u: Float, _ v: Float) -> [Int] {
            let point = polygon[0] + (polygon[1]-polygon[0])*u + (polygon[3]-polygon[0])*v
            let x = max(0,min(255,Int(point.x))), y = max(0,min(255,Int(point.y))), offset = (y*256+x)*4
            return [Int(bytes[offset+2]),Int(bytes[offset+1]),Int(bytes[offset]),Int(bytes[offset+3])]
        }
        let tl = sample(pixels,0.25,0.25), tr = sample(pixels,0.75,0.25), br = sample(pixels,0.75,0.75), bl = sample(pixels,0.25,0.75)
        print("GPU quadrant RGBA: \(tl), \(tr), \(br), \(bl)")
        fflush(stdout)
        check(tl[0] > 230 && tl[1] < 25 && tl[2] < 25,"top-left UV is red")
        check(tr[1] > 230 && tr[0] < 25 && tr[2] < 25,"top-right UV is green")
        check(br[0] > 230 && br[1] > 230 && br[2] < 25,"bottom-right UV is yellow")
        check(bl[2] > 230 && bl[0] < 25 && bl[1] < 25,"bottom-left UV is blue")
        let transparent = sample(try render(snapshot([("z-rear",blue),("a-front",clear)])),0.5,0.5)
        check(transparent[2] > 230 && transparent[0] < 25,"transparent foreground preserves rear texture")
        let opaque = sample(try render(snapshot([("z-rear",corners),("a-front",blue)])),0.25,0.25)
        check(opaque[2] > 230 && opaque[0] < 25 && opaque[1] < 25,"equal-depth opaque foreground uses captured order")
        // Hosting composite must be the only painted texture, including nested hosting descendants.
        let geometry: [String:Any] = ["coordinateSpace":"UIScreen.fixedCoordinateSpace points","corners":[[0.0,0.0],[200.0,0.0],[200.0,200.0],[0.0,200.0]]]
        let scope: [String:Any] = ["deviceID":"synthetic","bootIdentity":"synthetic-boot","displayID":"synthetic","presentation":"synthetic","generation":0,"runtime":"synthetic"]
        let nested: [String:Any] = ["id":"nested","className":"Synthetic nested hosting node","parentID":"child","children":[],"geometry":geometry]
        let child: [String:Any] = ["id":"child","className":"Synthetic representable","parentID":"host","children":[nested],"geometry":geometry,"assetID":"child"]
        let host: [String:Any] = ["id":"host","sceneID":"synthetic-scene","className":"Synthetic hosting node","parentID":NSNull(),"children":[child],"geometry":geometry,"assetID":"host"]
        func compositeAsset(_ id:String,_ png:String) -> [String:Any] {
            var a: [String:Any] = ["nodeID":id,"captureID":"capture","format":"png","encoding":"base64","pixelWidth":2,"pixelHeight":2,"data":png]
            if id == "host" { a["representation"] = "hostingSubtreeComposite"; a["descendantContent"] = "all" }
            return a
        }
        let compositeRaw: [String:Any] = ["captureID":"capture","capturedAt":"synthetic","roots":[host],"assets":["host":compositeAsset("host",corners),"child":compositeAsset("child",blue)],"inspectionScope":scope,"processLifetime":["synthetic":true],"swiftUI":["schemaVersion":1,"captureID":"capture","inspectionScope":scope,"hosts":[["hostingNodeID":"host","sceneID":"synthetic-scene","status":"empty","reason":NSNull(),"graphStatus":"emptyArray","nodes":[],"rendering":["status":"available","representation":"hostingSubtreeComposite","assetID":"host","drawHierarchyReturned":true,"reason":NSNull()]]]]]
        let composite = try SimulatorInspectorSnapshot.parse(compositeRaw,context:context)
        let compositePixels = try render(composite)
        print("Composite mismatch bytes: \(zip(compositePixels,pixels).filter { $0 != $1 }.count); cache \(renderer.cachedTextureCount); sample \(sample(compositePixels,0.25,0.25))"); fflush(stdout)
        check(compositePixels == pixels,"actual GPU composite equals single hosting texture; child blue texture suppressed")
        check(renderer.cachedTextureCount == 1,"suppressed descendant textures are not decoded/uploaded")
        renderer.selection = "child"
        check(renderer.candidates(at:SIMD2(128,128)).contains("child"),"suppressed UIKit descendant retains valid picking geometry")
        renderer.releaseCapture()
        check(renderer.textureFailures.isEmpty,"capture cache released")
        print("PASS \(checks) actual GPU assertions; no window ordered, no Simulator or guest input")
    }
}
