import CoreMedia
import CoreVideo
import Foundation
import Shared
import VideoToolbox

/// What the host sends must decode on every viewer (the Mac and the iPhone share Depacketizer): encode a few frames,
/// packetize them, turn them back into sample buffers and decode those.
func testVideoRoundTrip() throws {
    let (w, h) = (320, 240)
    for (name, codec) in [("h264", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC)] {
        var enc: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                   compressionSessionOut: &enc)
        guard let enc else { throw RegressionFailure(message: "\(name): no encoder") }
        defer { VTCompressionSessionInvalidate(enc) }
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        var packets: [Data] = []
        for i in 0..<3 {
            var px: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &px)
            guard let px else { throw RegressionFailure(message: "\(name): no pixel buffer") }
            CVPixelBufferLockBaseAddress(px, [])
            memset(CVPixelBufferGetBaseAddress(px), Int32(40 + i * 60), CVPixelBufferGetDataSize(px))
            CVPixelBufferUnlockBaseAddress(px, [])
            let done = DispatchSemaphore(value: 0)
            let props = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(enc, imageBuffer: px, presentationTimeStamp: CMTime(value: Int64(i), timescale: 60),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sb in
                if status == noErr, let sb { packets.append(packet(sb, UInt32(i))) }
                done.signal()
            }
            VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
            done.wait()
        }
        try expectEqual(packets.count, 3)
        try expectEqual(packets[0][4] & 0x80 != 0, codec == kCMVideoCodecType_HEVC)   // HEVC bit
        try expectTrue(packets[0][4] & 0x7f > 0)                                        // keyframe carries parameter sets

        var early = Depacketizer()
        try expectTrue(early.sampleBuffer(packets[1]) == nil)   // nothing to decode with before a keyframe

        var d = Depacketizer()
        var decoder: VTDecompressionSession?
        var decoded = 0
        for (i, p) in packets.enumerated() {
            guard let (seq, sb) = d.sampleBuffer(p), let format = d.format else {
                throw RegressionFailure(message: "\(name): packet \(i) gave no sample buffer")
            }
            try expectEqual(seq, UInt32(i))
            if decoder == nil {
                VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
            }
            guard let decoder else { throw RegressionFailure(message: "\(name): no decoder") }
            VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image, CVPixelBufferGetWidth(image) == w, CVPixelBufferGetHeight(image) == h { decoded += 1 }
            }
        }
        decoder.map { VTDecompressionSessionWaitForAsynchronousFrames($0); VTDecompressionSessionInvalidate($0) }
        try expectEqual(decoded, 3)
    }
}

/// Taps and clicks land where they look like they land, with the picture scaled and letterboxed.
func testRemotePoint() throws {
    // a 400×100 window shown in a 200×100 view: half size, 25 pt bars above and below
    try expectEqual(remotePoint(CGPoint(x: 100, y: 50), view: CGSize(width: 200, height: 100), remote: CGSize(width: 400, height: 100)),
                    CGPoint(x: 200, y: 50))
    try expectEqual(remotePoint(CGPoint(x: 0, y: 25), view: CGSize(width: 200, height: 100), remote: CGSize(width: 400, height: 100)),
                    CGPoint(x: 0, y: 0))
    // same size: unchanged; unknown remote size: unchanged
    try expectEqual(remotePoint(CGPoint(x: 7, y: 9), view: CGSize(width: 300, height: 200), remote: CGSize(width: 300, height: 200)),
                    CGPoint(x: 7, y: 9))
    try expectEqual(remotePoint(CGPoint(x: 7, y: 9), view: CGSize(width: 300, height: 200), remote: .zero), CGPoint(x: 7, y: 9))
}
