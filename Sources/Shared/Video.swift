import CoreMedia
import Foundation

/// Video packet: [inputSeq u32][paramCount u8, bit 7 = HEVC]([len u16][parameter set])*[length-prefixed NAL units]
public func packet(_ sb: CMSampleBuffer, _ seq: UInt32) -> Data {
    var d = Data()
    d.put(seq)
    let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
    let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    var params: [Data] = []
    let hevc = sb.formatDescription.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC } ?? false
    if isKey, let fd = sb.formatDescription, hevc {
        var n = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
        for i in 0..<n {
            var p: UnsafePointer<UInt8>?, len = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                               parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p { params.append(Data(bytes: p, count: len)) }
        }
    } else if isKey, let fd = sb.formatDescription {
        var n = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
        for i in 0..<n {
            var p: UnsafePointer<UInt8>?, len = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                               parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p { params.append(Data(bytes: p, count: len)) }
        }
    }
    d.put(UInt8(params.count) | (hevc ? 0x80 : 0))   // high bit: HEVC parameter sets (VPS/SPS/PPS)
    for p in params { d.put(UInt16(p.count)); d.append(p) }
    if let bb = sb.dataBuffer {
        let len = CMBlockBufferGetDataLength(bb)
        var body = Data(count: len)
        body.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        d.append(body)
    }
    return d
}


/// The viewer's half: packets back into sample buffers a display layer shows at once. Keeps the format from the last
/// keyframe's parameter sets, so frames before the first keyframe are dropped.
public struct Depacketizer {
    public private(set) var format: CMVideoFormatDescription?
    public init() {}

    /// The frame and the input seq the host stamped on it, or nil until there's a format to decode with.
    public mutating func sampleBuffer(_ packet: Data) -> (seq: UInt32, buffer: CMSampleBuffer)? {
        var r = Reader(packet)
        let seq = r.u32()
        let pc = r.u8(), hevc = pc & 0x80 != 0
        let params = (0..<Int(pc & 0x7f)).map { _ in r.bytes(Int(r.u16())) }
        let body = r.rest()

        if !params.isEmpty {
            let bufs = params.map { p -> UnsafeMutablePointer<UInt8> in
                let m = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count)
                p.copyBytes(to: m, count: p.count)
                return m
            }
            defer { bufs.forEach { $0.deallocate() } }
            var fd: CMFormatDescription?
            let ptrs = bufs.map { UnsafePointer($0) }, sizes = params.map(\.count)
            if hevc {
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            } else {
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
            if let fd { format = fd }
        }
        guard let format, !body.isEmpty else { return nil }

        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: body.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        guard let bb else { return nil }
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: body.count) }
        var sb: CMSampleBuffer?
        var size = body.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard let sb else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return (seq, sb)
    }
}

/// A point in a view that shows the remote window aspect-fit → the same spot in the remote window. When the sizes
/// differ (full screen, an app that refused to shrink, a phone) the picture is scaled and letterboxed, and input has
/// to follow.
/// Where the picture goes in a view: `zoom` nil = fit (letterboxed), else remote points × zoom, centered when smaller
/// than the view and shifted by `pan` (how far it's scrolled, top-left origin) when bigger. Returns the clamped pan too.
public func pictureRect(view: CGSize, remote r: CGSize, zoom: CGFloat?, pan: CGPoint) -> (rect: CGRect, pan: CGPoint) {
    guard r.width > 0, r.height > 0, view.width > 0, view.height > 0 else { return (CGRect(origin: .zero, size: view), .zero) }
    let z = zoom ?? min(view.width / r.width, view.height / r.height)
    let w = r.width * z, h = r.height * z
    let pan = CGPoint(x: w > view.width ? min(max(pan.x, 0), w - view.width) : 0,
                      y: h > view.height ? min(max(pan.y, 0), h - view.height) : 0)
    let x = w > view.width ? -pan.x : (view.width - w) / 2, y = h > view.height ? -pan.y : (view.height - h) / 2
    return (CGRect(x: x, y: y, width: w, height: h), pan)
}

/// A point in the view → the same spot on the host, given where the picture is (`pictureRect`).
public func remotePoint(_ p: CGPoint, in rect: CGRect, remote r: CGSize) -> CGPoint {
    guard rect.width > 0, rect.height > 0 else { return p }
    return CGPoint(x: (p.x - rect.minX) * r.width / rect.width, y: (p.y - rect.minY) * r.height / rect.height)
}

public func remotePoint(_ p: CGPoint, view: CGSize, remote r: CGSize) -> CGPoint {
    guard r.width > 0, r.height > 0, view.width > 0, view.height > 0 else { return p }
    let s = min(view.width / r.width, view.height / r.height)
    return CGPoint(x: (p.x - (view.width - r.width * s) / 2) / s, y: (p.y - (view.height - r.height * s) / 2) / s)
}
