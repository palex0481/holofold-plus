// Host check for the recorder's st3d tagging (macOS, Foundation + AVFoundation only):
//   swiftc -o /tmp/st3dcheck App/Sources/Vision/StereoFrameSource.swift scripts/tools/st3d-check/main.swift
//   /tmp/st3dcheck            # encodes a 3200x1920 H.264 test clip, tags it, verifies st3d = 2
//   /tmp/st3dcheck clip.mp4   # just reports a clip's st3d stereo_mode
import AVFoundation
import Foundation

func makeClip(_ url: URL, width: Int, height: Int) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = false
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw NSError(domain: "H.264 refused \(width)x\(height)", code: 1) }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 60))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "write failed", code: 2) }
}

let args = CommandLine.arguments
if args.count > 1 {
    let mode = try MP4StereoTag.stereoMode(URL(fileURLWithPath: args[1]))
    print(mode.map { "st3d stereo_mode \($0)" } ?? "no st3d")
    exit(mode == 2 ? 0 : 1)
}
let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("st3d-test.mp4")
try makeClip(url, width: 3200, height: 1920)
let before = try MP4StereoTag.stereoMode(url)
try MP4StereoTag.tagLeftRight(url)
let after = try MP4StereoTag.stereoMode(url)
let asset = AVURLAsset(url: url)
let tracks = try await asset.loadTracks(withMediaType: .video)
let dur = try await asset.load(.duration)
let frames = try await tracks.first?.load(.naturalSize)
print("before \(before.map(String.init) ?? "none"), after \(after.map(String.init) ?? "none"), size \(frames ?? .zero), duration \(dur.seconds)s")
exit(after == 2 && before == nil && tracks.count == 1 ? 0 : 1)
