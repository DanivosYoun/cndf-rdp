import Metal
import MetalKit
import RDPClientCore

final class RDPMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let lock = NSLock()
    private let inFlightCondition = NSCondition()
    private var texture: MTLTexture?
    private var frameSize: CGSize = .zero
    private var isShutdown = false
    private var inFlightCommandBuffers = 0

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 texCoords[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 fragment_main(VertexOut in [[stage_in]],
                                      texture2d<float> colorTexture [[texture(0)]],
                                      sampler textureSampler [[sampler(0)]]) {
            return colorTexture.sample(textureSampler, in.texCoord);
        }
        """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.samplerState = samplerState

        super.init()
        view.device = device
        view.delegate = self
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
    }

    func update(frame: RDPFrame) {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else {
            return
        }
        lock.lock()
        let canUpdate = !isShutdown
        lock.unlock()
        guard canUpdate else {
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            return
        }

        frame.bgra.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            newTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: frame.stride
            )
        }

        lock.lock()
        texture = newTexture
        frameSize = CGSize(width: frame.width, height: frame.height)
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let canDraw = !isShutdown
        let currentTexture = texture
        let currentFrameSize = frameSize
        lock.unlock()

        guard canDraw else {
            return
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        encoder.setRenderPipelineState(pipelineState)

        if let currentTexture, currentFrameSize.width > 0, currentFrameSize.height > 0 {
            let viewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: view.drawableSize.width,
                height: view.drawableSize.height,
                znear: 0,
                zfar: 1
            )
            encoder.setViewport(viewport)
            encoder.setFragmentTexture(currentTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()

        inFlightCondition.lock()
        inFlightCommandBuffers += 1
        inFlightCondition.unlock()
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.inFlightCondition.lock()
            self.inFlightCommandBuffers = max(0, self.inFlightCommandBuffers - 1)
            self.inFlightCondition.broadcast()
            self.inFlightCondition.unlock()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func shutdown(waitTimeout: TimeInterval = 1.0) -> Int {
        lock.lock()
        isShutdown = true
        texture = nil
        frameSize = .zero
        lock.unlock()

        return waitForInFlightCommandBuffers(timeout: waitTimeout)
    }

    private func waitForInFlightCommandBuffers(timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        inFlightCondition.lock()
        defer { inFlightCondition.unlock() }

        while inFlightCommandBuffers > 0 {
            if !inFlightCondition.wait(until: deadline) {
                break
            }
        }
        return inFlightCommandBuffers
    }
}
