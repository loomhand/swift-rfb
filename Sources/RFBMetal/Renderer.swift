import Metal
import QuartzCore
import RFB

// RFBRenderer draws a framebuffer, aliased as a texture without a copy, and
// optionally the remote cursor over it.
public final class RFBRenderer: @unchecked Sendable {
    public struct Surface: @unchecked Sendable {
        public let framebuffer: RFBFramebuffer
        let texture: MTLTexture
    }

    public struct CursorImage: @unchecked Sendable {
        public let cursor: RFBCursor
        let texture: MTLTexture
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut place(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        VOut out;
        out.position = float4(mix(rect.xy, rect.zw, corner), 0, 1);
        out.uv = float2(corner.x, 1 - corner.y);
        return out;
    }
    fragment half4 opaque(VOut in [[stage_in]], texture2d<half> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return half4(tex.sample(s, in.uv).rgb, 1);
    }
    fragment half4 blended(VOut in [[stage_in]], texture2d<half> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let opaque: MTLRenderPipelineState
    private let blended: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaders, options: nil)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "place")
        descriptor.fragmentFunction = library.makeFunction(name: "opaque")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let opaque = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        descriptor.fragmentFunction = library.makeFunction(name: "blended")
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .one
        blend.sourceAlphaBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let blended = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let sampler = MTLSamplerDescriptor()
        guard let nearest = device.makeSamplerState(descriptor: sampler) else { return nil }
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sampler) else { return nil }
        self.device = device
        self.queue = queue
        self.opaque = opaque
        self.blended = blended
        self.nearest = nearest
        self.linear = linear
    }

    public func makeSurface(_ framebuffer: RFBFramebuffer) -> Surface? {
        guard framebuffer.bytesPerRow % device.minimumLinearTextureAlignment(for: .bgra8Unorm) == 0,
              let buffer = device.makeBuffer(bytesNoCopy: framebuffer.baseAddress, length: framebuffer.length, options: .storageModeShared, deallocator: nil)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: framebuffer.width, height: framebuffer.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: framebuffer.bytesPerRow) else { return nil }
        return Surface(framebuffer: framebuffer, texture: texture)
    }

    public func makeCursor(_ cursor: RFBCursor) -> CursorImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cursor.width, height: cursor.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        cursor.pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, cursor.width, cursor.height), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: cursor.width * 4)
        }
        return CursorImage(cursor: cursor, texture: texture)
    }

    // draw renders into the next drawable of layer and presents it;
    // completed runs once the GPU no longer reads the framebuffer.
    @discardableResult
    public func draw(
        _ surface: Surface, cursor: (image: CursorImage, x: Int, y: Int)?, in layer: CAMetalLayer,
        presented: (@Sendable () -> Void)? = nil, completed: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let fb = surface.framebuffer
        let exact = drawable.texture.width == fb.width && drawable.texture.height == fb.height
        var full = SIMD4<Float>(-1, -1, 1, 1)
        encoder.setRenderPipelineState(opaque)
        encoder.setVertexBytes(&full, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(surface.texture, index: 0)
        encoder.setFragmentSamplerState(exact ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let cursor {
            let c = cursor.image.cursor
            let left = Float(cursor.x - c.hotspotX)
            let top = Float(cursor.y - c.hotspotY)
            let w = Float(fb.width)
            let h = Float(fb.height)
            var rect = SIMD4<Float>(left / w * 2 - 1, 1 - (top + Float(c.height)) / h * 2, (left + Float(c.width)) / w * 2 - 1, 1 - top / h * 2)
            encoder.setRenderPipelineState(blended)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(cursor.image.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        if let presented {
            drawable.addPresentedHandler { _ in presented() }
        }
        commands.addCompletedHandler { _ in
            withExtendedLifetime(fb) { completed() }
        }
        commands.present(drawable)
        commands.commit()
        return true
    }
}
