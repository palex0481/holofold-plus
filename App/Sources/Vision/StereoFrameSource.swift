#if os(visionOS)
import AzaharCore
import Metal
import os
import QuartzCore
import RealityKit
import AVFoundation
import CoreVideo

/// Feeds the emulator's frames into RealityKit textures.
///
/// Vulkan (device): the core renders side-by-side full-width stereo into an offscreen texture
/// ring (az_offscreen_*). Each RealityKit update takes the newest frame and blits it into one
/// LowLevelTexture; both panels sample it, the top one per eye (StereoScreen.usda).
/// Software renderer (Simulator): the two screens arrive as CPU pixels (az_get_software_frame) and
/// are uploaded into one texture each; there is no right eye then.
@MainActor
final class StereoFrameSource {
    /// Handed to the core with az_set_surface. The Vulkan renderer needs a surface to set up,
    /// but with offscreen output nothing is ever presented to it, so it is never shown.
    let layer = CAMetalLayer()
    /// Pixel size of the stereo frame: two eye halves of `eyeSize` side by side.
    let eyeSize: (width: Int, height: Int)
    var frameSize: (width: Int, height: Int) { (eyeSize.width * 2, eyeSize.height) }

    /// Where a panel samples: its texture and the rect of its screen for each eye, in 0...1.
    struct Source {
        let texture: TextureResource
        let left: CGRect
        let right: CGRect
    }
    /// Called when the texture or the screen rects change (first frame, size change).
    var onSources: ((_ top: Source?, _ bottom: Source?) -> Void)?
    /// Called on the main thread each time a new core frame has been blitted into the texture.
    var onFrameDelivered: (() -> Void)?
    /// 3D at 0 %: both eyes sample the left eye's image (one view, no right-eye texels read).
    var mono = false { didSet { if mono != oldValue { publish() } } }
    /// Bottom screen rect in surface pixels, for touch input.
    private(set) var bottomPixelRect: CGRect?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var stereoTexture: LowLevelTexture?
    private var stereoResource: TextureResource?
    private var generation: UInt64 = .max
    private var lastFrame: UInt64 = 0
    private var rects: (top: CGRect, bottom: CGRect)?
    /// Pumps since the screen rects were last read. They only change with the layout, and
    /// az_get_screen_rects takes the renderer's surface lock.
    private var pumpsSinceRects = 0
    /// One blit at a time. Holding every offscreen slot until the GPU finishes makes MoltenVK
    /// stall behind the exported textures; skipping acquire lets the core publish a newer frame.
    private let blitsInFlight = OSAllocatedUnfairLock(initialState: 0)

    /// Antialiasing of the displayed image: "visionAntialiasing" = "fxaa" (default) or "off".
    static var fxaaEnabled: Bool { (UserDefaults.standard.string(forKey: "visionAntialiasing") ?? "fxaa") != "off" }
    /// Compiled off the first frame. Until it is ready, frames are copied without FXAA.
    private var fxaaPipeline: MTLComputePipelineState?
    /// FXAA (console-quality variant after Timothy Lottes' FXAA 3.11), as a compute kernel.
    private static let fxaaSource = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
    kernel void fxaa(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 p = float2(gid) + 0.5;
        float4 m4 = src.sample(s, p);
        float lM = luma(m4.rgb);
        float lNW = luma(src.sample(s, p + float2(-1,-1)).rgb);
        float lNE = luma(src.sample(s, p + float2( 1,-1)).rgb);
        float lSW = luma(src.sample(s, p + float2(-1, 1)).rgb);
        float lSE = luma(src.sample(s, p + float2( 1, 1)).rgb);
        float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
        float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
        if (lMax - lMin < max(0.0312, lMax * 0.125)) { dst.write(m4, gid); return; }
        float2 dir = float2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));
        float reduce = max((lNW + lNE + lSW + lSE) * 0.03125, 1.0 / 128.0);
        float rcpMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
        dir = clamp(dir * rcpMin, -8.0, 8.0);
        float3 a = 0.5 * (src.sample(s, p + dir * (1.0/3.0 - 0.5)).rgb + src.sample(s, p + dir * (2.0/3.0 - 0.5)).rgb);
        float3 b = a * 0.5 + 0.25 * (src.sample(s, p - dir * 0.5).rgb + src.sample(s, p + dir * 0.5).rgb);
        float lB = luma(b);
        dst.write(float4((lB < lMin || lB > lMax) ? a : b, m4.a), gid);
    }
    """

    private var softwareTextures: [LowLevelTexture?] = [nil, nil]
    private var softwareResources: [TextureResource?] = [nil, nil]
    private var softwareCounter: UInt64 = 0
    private var softwareBuffer: [UInt8] = []

    init(eyeWidth: Int, eyeHeight: Int) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        eyeSize = (eyeWidth, eyeHeight)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: eyeWidth * 2, height: eyeHeight)
        let fxaaDevice = device
        let fxaaSource = Self.fxaaSource
        // makeLibrary(source:) is synchronous. Compiling on the first pump stalled the compositor.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let compiled = compileStereoFXAA(on: fxaaDevice, source: fxaaSource)
            Task { @MainActor in self?.fxaaPipeline = compiled }
        }
    }

    /// Gives the surface to the core: double width, portrait layout (top screen over bottom).
    func attach() {
        let ptr = Unmanaged.passUnretained(layer).toOpaque()
        az_set_surface(ptr, Int32(frameSize.width), Int32(frameSize.height), true)
    }

    func detach() {
        if !az_is_running() { az_set_surface(nil, 0, 0, false) }
    }

    /// Once per RealityKit frame.
    func pump() {
        VisionHangWatchdog.shared.pumped(frame: lastFrame)
        InputManager.shared.pollTouchpads()
        InputManager.shared.pollGamepads()
        updateRects()
        if az_is_software_renderer() {
            pumpSoftware()
        } else {
            pumpStereo()
        }
    }

    // MARK: Layout

    /// The core's screen rects (left-eye half, surface pixels). They only change with the layout,
    /// so after the first successful read they are refreshed every 60 pumps.
    private func updateRects() {
        if rects != nil {
            pumpsSinceRects += 1
            if pumpsSinceRects < 60 { return }
            pumpsSinceRects = 0
        }
        var t = AZScreenRect(), b = AZScreenRect()
        guard az_get_screen_rects(&t, &b) else { return }
        let top = CGRect(x: CGFloat(t.x), y: CGFloat(t.y), width: CGFloat(t.width), height: CGFloat(t.height))
        let bottom = CGRect(x: CGFloat(b.x), y: CGFloat(b.y), width: CGFloat(b.width), height: CGFloat(b.height))
        guard rects == nil || rects!.top != top || rects!.bottom != bottom else { return }
        rects = (top, bottom)
        bottomPixelRect = b.enabled ? bottom : nil
        publish()
    }

    private func publish() {
        if az_is_software_renderer() {
            let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
            onSources?(softwareResources[0].map { Source(texture: $0, left: whole, right: whole) },
                       softwareResources[1].map { Source(texture: $0, left: whole, right: whole) })
            return
        }
        guard let resource = stereoResource, let rects else { return }
        let w = CGFloat(frameSize.width), h = CGFloat(frameSize.height)
        func unit(_ r: CGRect, eye: Int) -> CGRect {
            CGRect(x: (r.minX + CGFloat(eye) * w / 2) / w, y: r.minY / h, width: r.width / w, height: r.height / h)
        }
        onSources?(Source(texture: resource, left: unit(rects.top, eye: 0), right: unit(rects.top, eye: mono ? 0 : 1)),
                   Source(texture: resource, left: unit(rects.bottom, eye: 0), right: unit(rects.bottom, eye: 0)))
    }

    // MARK: Vulkan offscreen frames

    private func pumpStereo() {
        let busy = blitsInFlight.withLock { $0 >= 1 }
        if busy { return }
        var frame = AZOffscreenFrame()
        guard az_offscreen_acquire(&frame) else { return }
        let slot = frame.slot
        guard frame.frame != lastFrame, let ptr = frame.texture else {
            az_offscreen_release(slot)
            return
        }
        let source = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as! MTLTexture
        if stereoTexture == nil || generation != frame.generation {
            generation = frame.generation
            do {
                // One mip level. A full chain (and generateMipmaps) on the 2x stereo frame ran
                // every pump and kept the offscreen slot until the GPU finished the whole chain.
                // Minifying the panel can shimmer a little; the window is normally close to 1:1.
                let texture = try LowLevelTexture(descriptor: .init(
                    textureType: .type2D, pixelFormat: source.pixelFormat,
                    width: source.width, height: source.height, depth: 1,
                    mipmapLevelCount: 1, textureUsage: [.shaderRead, .shaderWrite]))
                stereoTexture = texture
                stereoResource = try TextureResource(from: texture)
                VisionDiag.log("stereo: frame texture \(source.width)x\(source.height) format \(source.pixelFormat.rawValue)")
            } catch {
                NSLog("Holofold stereo: cannot create the frame texture: %@", "\(error)")
                az_offscreen_release(slot)
                return
            }
            publish()
        }
        guard let target = stereoTexture, let commands = queue.makeCommandBuffer() else {
            az_offscreen_release(slot)
            return
        }
        let destination = target.replace(using: commands)
        // FXAA on the composited stereo frame (Vulkan path only). The 3DS image is rendered by
        // the core at an integer scale; this smooths its stair-stepped edges for ~1 compute pass.
        var copied = false
        if Self.fxaaEnabled, let fxaa = fxaaPipeline, let compute = commands.makeComputeCommandEncoder() {
            compute.setComputePipelineState(fxaa)
            compute.setTexture(source, index: 0)
            compute.setTexture(destination, index: 1)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            compute.dispatchThreadgroups(MTLSize(width: (source.width + 15) / 16, height: (source.height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: tg)
            compute.endEncoding()
            copied = true
        }
        if !copied, let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                      to: destination, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        let inflight = blitsInFlight
        inflight.withLock { $0 += 1 }
        commands.addCompletedHandler { _ in
            az_offscreen_release(slot)
            inflight.withLock { $0 -= 1 }
        }
        // Demo recorder: copy the finished frame into a pixel buffer in the same command buffer.
        // It never waits; a busy encoder or an empty pool drops the frame instead.
        if let recorder = VisionRecorder.shared, recorder.isRecording, let rects {
            recorder.encode(from: destination, frameSize: frameSize, top: rects.top, bottom: rects.bottom,
                            mono: mono, commands: commands, device: device)
        }
        commands.commit()
        lastFrame = frame.frame
        onFrameDelivered?()
    }

    // MARK: Software renderer frames (Simulator)

    private func pumpSoftware() {
        var w: Int32 = 0, h: Int32 = 0
        let counter = az_get_software_frame(0, nil, 0, &w, &h)
        guard counter != 0, counter != softwareCounter else { return }
        softwareCounter = counter
        var changed = false
        for screen in 0..<2 {
            var sw: Int32 = 0, sh: Int32 = 0
            _ = az_get_software_frame(Int32(screen), nil, 0, &sw, &sh)
            guard sw > 0, sh > 0 else { continue }
            let size = Int(sw) * Int(sh) * 4
            if softwareBuffer.count < size { softwareBuffer = [UInt8](repeating: 0, count: size) }
            softwareBuffer.withUnsafeMutableBufferPointer { p in
                _ = az_get_software_frame(Int32(screen), p.baseAddress, Int32(size), &sw, &sh)
            }
            if softwareTextures[screen].map({ $0.descriptor.width != Int(sw) || $0.descriptor.height != Int(sh) }) ?? true {
                guard let texture = try? LowLevelTexture(descriptor: .init(
                    textureType: .type2D, pixelFormat: .rgba8Unorm, width: Int(sw), height: Int(sh),
                    depth: 1, mipmapLevelCount: 1, textureUsage: [.shaderRead, .shaderWrite])) else { continue }
                softwareTextures[screen] = texture
                softwareResources[screen] = try? TextureResource(from: texture)
                changed = true
            }
            guard let texture = softwareTextures[screen],
                  let staging = device.makeBuffer(bytes: softwareBuffer, length: size, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer() else { continue }
            let destination = texture.replace(using: commands)
            if let blit = commands.makeBlitCommandEncoder() {
                blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: Int(sw) * 4,
                          sourceBytesPerImage: size, sourceSize: MTLSize(width: Int(sw), height: Int(sh), depth: 1),
                          to: destination, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
            commands.commit()
        }
        if changed { publish() }
    }
}

/// Records the emulator's own stereo output to an MP4 (HEVC, full side-by-side: left eye | right eye),
/// optionally with the touch screen under the top screen in each eye. Only the app's own frames:
/// visionOS gives third-party apps no passthrough camera frames (that is the Enterprise
/// main-camera-access entitlement plus an Apple-issued license file).
final class VisionRecorder: @unchecked Sendable {
    /// Exists while a game window is up; StereoFrameSource feeds it.
    nonisolated(unsafe) static var shared: VisionRecorder? = VisionRecorder()
    static let includeTouchKey = "visionRecordIncludeTouch"
    nonisolated(unsafe) static var eyeWidthCap = 2048

    private let queue = DispatchQueue(label: "holofold.recorder", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var recording = false
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        var audioNext: Int64 = -1      // next audio PTS, in samples at the core's native rate
        var audioBlocks = 0
        var audioResyncs = 0
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var cache: CVMetalTextureCache?
        var pipeline: MTLComputePipelineState?
        var size: (Int, Int) = (0, 0)
        var start: CFTimeInterval = 0
        var lastTime: CFTimeInterval = -1
        var inFlight = 0
        var url: URL?
        var frames = 0
        var dropped = 0
    }
    var isRecording: Bool { lock.withLock { $0.recording } }

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() -> Bool {
        lock.withLock { state in
            guard !state.recording else { return true }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            state.url = Self.folder.appendingPathComponent("Holofold-\(f.string(from: Date()))-SBS.mp4")
            state.writer = nil; state.input = nil; state.adaptor = nil
            state.audioInput = nil; state.audioNext = -1; state.audioBlocks = 0; state.audioResyncs = 0
            state.size = (0, 0); state.lastTime = -1; state.frames = 0; state.dropped = 0
            state.recording = true
            // Game audio: the core hands over each mixed DSP block (before the speaker sink).
            az_set_audio_tap({ samples, frames, context in
                guard let samples, let context else { return }
                Unmanaged<VisionRecorder>.fromOpaque(context).takeUnretainedValue().appendAudio(samples, frames: frames)
            }, Unmanaged.passUnretained(self).toOpaque())
            let needsPipeline = state.pipeline == nil
            if needsPipeline {
                // makeLibrary(source:) is synchronous: compile off the main thread; frames drop until ready.
                queue.async { [lock] in
                    guard let device = MTLCreateSystemDefaultDevice(),
                          let lib = try? device.makeLibrary(source: Self.kernel, options: nil),
                          let fn = lib.makeFunction(name: "rec"),
                          let pipeline = try? device.makeComputePipelineState(function: fn) else {
                        VisionDiag.log("recorder: pipeline unavailable"); return
                    }
                    lock.withLock { $0.pipeline = pipeline }
                }
            }
            return true
        }
    }

    /// Finishes the file; the URL comes back on the main actor (nil when nothing was written).
    func stop(_ done: @escaping @MainActor (URL?) -> Void) {
        az_set_audio_tap(nil, nil)
        let (writer, input, audio, url, frames, dropped, blocks, resyncs) = lock.withLock { s -> (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, URL?, Int, Int, Int, Int) in
            s.recording = false
            defer { s.writer = nil; s.input = nil; s.audioInput = nil; s.adaptor = nil }
            return (s.writer, s.input, s.audioInput, s.url, s.frames, s.dropped, s.audioBlocks, s.audioResyncs)
        }
        queue.async {
            guard let writer, let input, writer.status == .writing else {
                Task { @MainActor in done(nil) }
                return
            }
            input.markAsFinished()
            audio?.markAsFinished()
            writer.finishWriting {
                VisionDiag.log("recorder: \(writer.status == .completed ? "saved" : "failed") \(url?.lastPathComponent ?? "-") frames \(frames) dropped \(dropped) audio \(audio == nil ? "none" : "AAC") blocks \(blocks) resyncs \(resyncs)")
                let ok = writer.status == .completed
                // YouTube 3D: tag the clip left-right (st3d) before Share clip is offered.
                if ok, let url {
                    do { try MP4StereoTag.tagLeftRight(url) ; VisionDiag.log("recorder: st3d left-right written") }
                    catch { VisionDiag.log("recorder: st3d rewrite failed, original clip kept: \(error)") }
                }
                Task { @MainActor in done(ok ? url : nil) }
            }
        }
    }

    private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    struct P { float4 left; float4 right; };
    kernel void rec(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant P& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;
        uint half_w = w / 2;
        bool right = gid.x >= half_w;
        float4 r = right ? p.right : p.left;
        float2 uv = float2((float(gid.x - (right ? half_w : 0)) + 0.5) / float(half_w), (float(gid.y) + 0.5) / float(h));
        dst.write(float4(src.sample(s, r.xy + uv * r.zw).rgb, 1.0), gid);
    }
    """

    /// Emulator audio thread. Audio PTS runs on the sample count (gap-free); it is pinned to the
    /// same host clock as the video frames and re-pinned if emulation speed drifts it > 100 ms.
    fileprivate func appendAudio(_ samples: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        let rate = Int64(az_audio_sample_rate())
        let now = CACurrentMediaTime()
        let job: (AVAssetWriterInput, CMAudioFormatDescription, Int64)? = lock.withLock { s in
            guard s.recording, let audio = s.audioInput, let format = s.audioFormat, s.writer?.status == .writing,
                  audio.isReadyForMoreMediaData else { return nil }
            let hostSamples = Int64((now - s.start) * Double(rate))
            if s.audioNext < 0 || abs(hostSamples - s.audioNext) > rate / 10 {
                if s.audioNext >= 0 { s.audioResyncs += 1 }
                s.audioNext = max(0, hostSamples)
            }
            let pts = s.audioNext
            s.audioNext += Int64(frames)
            s.audioBlocks += 1
            return (audio, format, pts)
        }
        guard let (audio, format, pts) = job else { return }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: CMTime(value: pts, timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr, let buffer else { return }
        audio.append(buffer)
    }

    /// Called on the main actor from the frame pump, inside the frame's command buffer.
    func encode(from texture: MTLTexture, frameSize: (width: Int, height: Int), top: CGRect, bottom: CGRect,
                mono: Bool, commands: MTLCommandBuffer, device: MTLDevice) {
        let includeTouch = UserDefaults.standard.object(forKey: Self.includeTouchKey) as? Bool ?? true
        let fw = CGFloat(frameSize.width), fh = CGFloat(frameSize.height), eyeW = fw / 2
        // Source region of one eye, in surface pixels of the left half.
        let region = includeTouch ? top.union(bottom) : top
        func unit(_ eye: Int) -> SIMD4<Float> {
            SIMD4(Float((region.minX + CGFloat(eye) * eyeW) / fw), Float(region.minY / fh),
                  Float(region.width / fw), Float(region.height / fh))
        }
        // Output: two eye halves; even sizes, at most 4096 wide (encoder limit headroom).
        // H.264 High 5.2 allows 36,864 macroblocks a frame; 3200x1920 at 4x is 24,000. Each eye is
        // capped at 2048 wide (4096 total); if the encoder refuses the size, 1920 per eye (3840 total).
        var ew = Int(region.width), eh = Int(region.height)
        let cap = Self.eyeWidthCap
        let scale = min(1.0, Double(cap) / Double(max(ew, 1)))
        ew = Int(Double(ew) * scale) & ~1; eh = Int(Double(eh) * scale) & ~1
        guard ew > 0, eh > 0 else { return }
        let size = (ew * 2, eh)

        let now = CACurrentMediaTime()
        let prepared: (AVAssetWriterInputPixelBufferAdaptor, CVMetalTextureCache, MTLComputePipelineState, CMTime)? = lock.withLock { s in
            guard s.recording else { return nil }
            if s.writer == nil || s.size != size {
                guard s.writer == nil else { s.dropped += 1; return nil }   // layout changed mid-clip: keep the first size
                guard let url = s.url, let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { s.recording = false; return nil }
                // moov at the end: the st3d insert then moves no chunk offsets (handled anyway).
                writer.shouldOptimizeForNetworkUse = false
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 40_000_000,
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoMaxKeyFrameIntervalKey: 60,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    ],
                ])
                input.expectsMediaDataInRealTime = true
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ])
                guard writer.canApply(outputSettings: input.outputSettings, forMediaType: .video), writer.canAdd(input) else {
                    if Self.eyeWidthCap > 1920 {
                        Self.eyeWidthCap = 1920
                        VisionDiag.log("recorder: H.264 refused \(size.0)x\(size.1), capping each eye at 1920")
                        return nil   // the next frame retries at the smaller size
                    }
                    s.recording = false; return nil
                }
                writer.add(input)
                // AAC stereo, resampled by the writer from the DSP's native 32,728 Hz.
                let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                                                    AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000]
                var asbd = AudioStreamBasicDescription(mSampleRate: Float64(az_audio_sample_rate()), mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
                var format: CMAudioFormatDescription?
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                               magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
                if let format, writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: format)
                    audio.expectsMediaDataInRealTime = true
                    if writer.canAdd(audio) { writer.add(audio); s.audioInput = audio; s.audioFormat = format }
                }
                if s.audioInput == nil { VisionDiag.log("recorder: AAC audio unavailable, video only") }
                guard writer.startWriting() else { s.recording = false; return nil }
                writer.startSession(atSourceTime: .zero)
                s.writer = writer; s.input = input; s.adaptor = adaptor; s.size = size; s.start = now
                if s.cache == nil {
                    var cache: CVMetalTextureCache?
                    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
                    s.cache = cache
                }
                VisionDiag.log("recorder: started \(size.0)x\(size.1) H.264\(s.audioInput == nil ? "" : " + AAC") -> \(url.lastPathComponent)")
            }
            // Drop rather than stall: at most 3 frames in flight, input must be ready, ~60 fps cap.
            let t = now - s.start
            guard let adaptor = s.adaptor, let cache = s.cache, let pipeline = s.pipeline,
                  s.inFlight < 3, s.input?.isReadyForMoreMediaData == true, t - s.lastTime >= 1.0 / 62.0 else {
                s.dropped += 1; return nil
            }
            s.lastTime = t
            s.inFlight += 1
            return (adaptor, cache, pipeline, CMTime(seconds: t, preferredTimescale: 60_000))
        }
        guard let (adaptor, cache, pipeline, time) = prepared else { return }
        func release() { lock.withLock { $0.inFlight -= 1; $0.dropped += 1 } }
        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { release(); return }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, size.0, size.1, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let target = CVMetalTextureGetTexture(cvTexture),
              let compute = commands.makeComputeCommandEncoder() else { release(); return }
        var params = (unit(0), unit(mono ? 0 : 1))
        compute.setComputePipelineState(pipeline)
        compute.setTexture(texture, index: 0)
        compute.setTexture(target, index: 1)
        compute.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        compute.dispatchThreadgroups(MTLSize(width: (size.0 + 15) / 16, height: (size.1 + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        let recLock = self.lock
        commands.addCompletedHandler { [queue] _ in
            queue.async {
                _ = cvTexture   // keeps the Metal view of the buffer alive until the GPU is done
                let appended = recLock.withLock { s -> Bool in
                    s.inFlight -= 1
                    guard s.recording, s.input?.isReadyForMoreMediaData == true else { s.dropped += 1; return false }
                    s.frames += 1
                    return true
                }
                if appended { adaptor.append(pixelBuffer, withPresentationTime: time) }
            }
        }
    }
}

/// Metal shader compile is synchronous and used to run on the first RealityKit pump.
private func compileStereoFXAA(on device: MTLDevice, source: String) -> MTLComputePipelineState? {
    do {
        let library = try device.makeLibrary(source: source, options: nil)
        guard let fn = library.makeFunction(name: "fxaa") else {
            VisionDiag.log("fxaa: pipeline unavailable: missing function")
            return nil
        }
        return try device.makeComputePipelineState(function: fn)
    } catch {
        VisionDiag.log("fxaa: pipeline unavailable: \(error)")
        return nil
    }
}
#endif

import Foundation

/// Adds Google's spatial-media st3d box (stereo_mode 2 = left-right) to every avc1/hvc1 sample
/// entry of an MP4, in place: rewrites moov into a temp file, then atomically replaces the clip.
/// Parent sizes (stsd, stbl, minf, mdia, trak, moov) are fixed up; if moov sits before mdat,
/// stco/co64 chunk offsets are shifted by the bytes added. Foundation only (host-testable).
enum MP4StereoTag {
    enum Failure: Error { case malformed(String), noMoov, noVideoEntry }

    static let st3dLeftRight: [UInt8] = [0, 0, 0, 13, 0x73, 0x74, 0x33, 0x64, 0, 0, 0, 0, 2]

    struct Box { let type: String; let start: Int; let header: Int; let size: Int }

    /// Boxes directly inside data[range].
    static func children(_ d: [UInt8], _ from: Int, _ to: Int) throws -> [Box] {
        var out: [Box] = [], p = from
        while p + 8 <= to {
            var size = Int(be32(d, p)), header = 8
            let type = String(bytes: d[(p + 4)..<(p + 8)], encoding: .isoLatin1) ?? "????"
            if size == 1 { guard p + 16 <= to else { throw Failure.malformed("largesize") }; size = Int(be64(d, p + 8)); header = 16 }
            else if size == 0 { size = to - p }
            guard size >= header, p + size <= to else { throw Failure.malformed("box \(type) at \(p)") }
            out.append(Box(type: type, start: p, header: header, size: size))
            p += size
        }
        return out
    }

    static func be32(_ d: [UInt8], _ p: Int) -> UInt32 { d[p..<(p + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
    static func be64(_ d: [UInt8], _ p: Int) -> UInt64 { d[p..<(p + 8)].reduce(0) { $0 << 8 | UInt64($1) } }
    static func put32(_ d: inout [UInt8], _ p: Int, _ v: UInt32) { for i in 0..<4 { d[p + i] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(i))) } }
    static func put64(_ d: inout [UInt8], _ p: Int, _ v: UInt64) { for i in 0..<8 { d[p + i] = UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64(i))) } }

    /// Top-level boxes of the file: (type, offset, size), reading headers only.
    static func topLevel(_ h: FileHandle, fileSize: Int) throws -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = [], p = 0
        while p + 8 <= fileSize {
            try h.seek(toOffset: UInt64(p))
            let head = [UInt8](try h.read(upToCount: 16) ?? Data())
            guard head.count >= 8 else { break }
            var size = Int(be32(head, 0))
            let type = String(bytes: head[4..<8], encoding: .isoLatin1) ?? "????"
            if size == 1 { guard head.count >= 16 else { throw Failure.malformed("top largesize") }; size = Int(be64(head, 8)) }
            else if size == 0 { size = fileSize - p }
            guard size >= 8, p + size <= fileSize else { throw Failure.malformed("top box \(type)") }
            out.append((type, p, size)); p += size
        }
        return out
    }

    /// The moov box with st3d inserted; `added` is the byte growth. Throws when nothing to tag.
    static func taggedMoov(_ moov: [UInt8], shiftOffsetsBy shiftBase: Bool) throws -> [UInt8] {
        var d = moov
        // Insert positions (absolute in d) and the chain of box starts that contain each.
        var inserts: [(at: Int, parents: [Int])] = []
        let top = try children(d, 0, d.count)
        guard let mv = top.first, mv.type == "moov" else { throw Failure.noMoov }
        for trak in try children(d, mv.start + mv.header, mv.start + mv.size) where trak.type == "trak" {
            guard let mdia = try children(d, trak.start + trak.header, trak.start + trak.size).first(where: { $0.type == "mdia" }),
                  let minf = try children(d, mdia.start + mdia.header, mdia.start + mdia.size).first(where: { $0.type == "minf" }),
                  let stbl = try children(d, minf.start + minf.header, minf.start + minf.size).first(where: { $0.type == "stbl" }),
                  let stsd = try children(d, stbl.start + stbl.header, stbl.start + stbl.size).first(where: { $0.type == "stsd" })
            else { continue }
            // stsd: FullBox (4) + entry_count (4), then sample entries.
            for entry in try children(d, stsd.start + stsd.header + 8, stsd.start + stsd.size)
            where ["avc1", "avc3", "hvc1", "hev1"].contains(entry.type) {
                // VisualSampleEntry fields: 78 bytes after the header, then child boxes.
                let kids = try children(d, entry.start + entry.header + 78, entry.start + entry.size)
                if kids.contains(where: { $0.type == "st3d" }) { continue }
                let required = kids.lastIndex(where: { ["avcC", "hvcC"].contains($0.type) })
                let at = required.map { kids[$0].start + kids[$0].size } ?? (entry.start + entry.header + 78)
                inserts.append((at, [mv.start, trak.start, mdia.start, minf.start, stbl.start, stsd.start, entry.start]))
            }
        }
        guard !inserts.isEmpty else { throw Failure.noVideoEntry }
        let added = inserts.count * st3dLeftRight.count
        // Shift chunk offsets first (positions are still the original ones).
        if shiftBase {
            for trak in try children(d, mv.start + mv.header, mv.start + mv.size) where trak.type == "trak" {
                try shiftChunkOffsets(&d, trak.start + trak.header, trak.start + trak.size, by: added)
            }
        }
        // Grow parent sizes, then insert from the back so earlier positions stay valid.
        for ins in inserts {
            for parent in ins.parents {
                if be32(d, parent) == 1 { put64(&d, parent + 8, be64(d, parent + 8) + UInt64(st3dLeftRight.count)) }
                else { put32(&d, parent, be32(d, parent) + UInt32(st3dLeftRight.count)) }
            }
        }
        for ins in inserts.sorted(by: { $0.at > $1.at }) { d.insert(contentsOf: st3dLeftRight, at: ins.at) }
        return d
    }

    private static func shiftChunkOffsets(_ d: inout [UInt8], _ from: Int, _ to: Int, by delta: Int) throws {
        for b in try children(d, from, to) {
            let body = b.start + b.header
            switch b.type {
            case "mdia", "minf", "stbl": try shiftChunkOffsets(&d, body, b.start + b.size, by: delta)
            case "stco":
                let n = Int(be32(d, body + 4))
                for i in 0..<n { let p = body + 8 + 4 * i; put32(&d, p, be32(d, p) + UInt32(delta)) }
            case "co64":
                let n = Int(be32(d, body + 4))
                for i in 0..<n { let p = body + 8 + 8 * i; put64(&d, p, be64(d, p) + UInt64(delta)) }
            default: break
            }
        }
    }

    static func tagLeftRight(_ url: URL) throws {
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let boxes = try topLevel(input, fileSize: fileSize)
        guard let moov = boxes.first(where: { $0.0 == "moov" }) else { throw Failure.noMoov }
        let mdatAfter = boxes.contains { $0.0 == "mdat" && $0.1 > moov.1 }
        try input.seek(toOffset: UInt64(moov.1))
        let moovBytes = [UInt8](try input.read(upToCount: moov.2) ?? Data())
        guard moovBytes.count == moov.2 else { throw Failure.malformed("short moov") }
        let tagged = try taggedMoov(moovBytes, shiftOffsetsBy: mdatAfter)

        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).st3d.tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: temp)
            func copy(_ from: Int, _ count: Int) throws {
                try input.seek(toOffset: UInt64(from))
                var left = count
                while left > 0 {
                    let chunk = try input.read(upToCount: min(left, 8 << 20)) ?? Data()
                    guard !chunk.isEmpty else { throw Failure.malformed("short read") }
                    try out.write(contentsOf: chunk); left -= chunk.count
                }
            }
            try copy(0, moov.1)
            try out.write(contentsOf: Data(tagged))
            try copy(moov.1 + moov.2, fileSize - moov.1 - moov.2)
            try out.synchronize(); try out.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// For checks: stereo_mode of the first st3d found in a video sample entry, or nil.
    static func stereoMode(_ url: URL) throws -> UInt8? {
        let d = [UInt8](try Data(contentsOf: url))
        func walk(_ from: Int, _ to: Int) throws -> UInt8? {
            for b in try children(d, from, to) {
                let body = b.start + b.header
                switch b.type {
                case "moov", "trak", "mdia", "minf", "stbl": if let m = try walk(body, b.start + b.size) { return m }
                case "stsd": if let m = try walk(body + 8, b.start + b.size) { return m }
                case "avc1", "avc3", "hvc1", "hev1": if let m = try walk(body + 78, b.start + b.size) { return m }
                case "st3d": return d[body + 4]
                default: break
                }
            }
            return nil
        }
        return try walk(0, d.count)
    }
}
