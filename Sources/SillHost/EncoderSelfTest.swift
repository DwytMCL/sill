import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import StreamProtocol

/// Local diagnostic, never a client/device acceptance test. The standalone diagnostic harness
/// selects one mode and bounds the process; the legacy flag exercises all three modes.
package enum EncoderSelfTest {
    package static func run(mode: EncoderMode? = nil, frames: Int = 300, outputDirectory: URL? = nil) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard (1...300).contains(frames) else { print("FAIL: frames must be 1...300"); exit(1) }
        var encoders: CFArray?
        let listStatus = VTCopyVideoEncoderList(nil, &encoders)
        print("VTCopyVideoEncoderList=\(listStatus); listed capability is not session readback")
        for item in encoders as? [[CFString: Any]] ?? [] where (item[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC {
            print("  HEVC encoder: \(item)")
        }
        var failed = false, unsupported = false
        for requested in mode.map({ [$0] }) ?? [.auto, .hardware, .software] {
            let status = check(mode: requested, frames: frames, outputDirectory: outputDirectory)
            failed = failed || status == 1
            unsupported = unsupported || status == 2
        }
        Stats.shared.dump()
        exit(failed ? 1 : unsupported ? 2 : 0)
    }

    private static func check(mode: EncoderMode, frames: Int, outputDirectory: URL?) -> Int32 {
        print("== requested \(mode.rawValue): 1280×720 420f, 30 fps, 4 Mbps, \(frames) frames")
        var decoder: VTDecompressionSession?
        defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
        do {
            let enc = try HEVCEncoder(width: 1280, height: 720, fps: 30, bitrate: 4_000_000,
                                      prioritizeSpeed: false, mode: mode, quiet: true)
            report(enc.capabilities)
            let samples = Samples()
            enc.onEncodedSample = { samples.put($0) }
            var stream = Data(), keyframes = 0
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<frames {
                // Pace a controlled moving fixture. Admission stays one at a time: this is a
                // capability/decode check, not a claim of sustained real-capture throughput.
                let wait = start + Double(i) / 30 - CFAbsoluteTimeGetCurrent()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                guard let pb = frame(index: i) else { throw Failure.message("pixel buffer allocation") }
                enc.encode(pb, pts: CMTime(value: CMTimeValue(i), timescale: 30))
                guard let sb = samples.take(timeout: 1) else {
                    enc.abandon()
                    var c = enc.capabilities; c.probeOutcome = .timedOut; report(c)
                    throw Failure.message("no sample within 1 s at frame \(i)")
                }
                guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), CMTime(value: CMTimeValue(i), timescale: 30)) == 0,
                      let format = CMSampleBufferGetFormatDescription(sb),
                      let ps = HEVCEncoder.parameterSets(from: format), ps.sets.count >= 3,
                      let roundtrip = ParameterSets(encoded: ps.encoded()), roundtrip.sets == ps.sets,
                      roundtrip.nalUnitHeaderLength == ps.nalUnitHeaderLength,
                      let block = CMSampleBufferGetDataBuffer(sb) else { throw Failure.message("PTS/parameter sets/sample block at frame \(i)") }
                let isKey = !((CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                guard !bytes.isEmpty else { throw Failure.message("empty sample") }
                let byteCount = bytes.count
                let copied = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
                }
                try require(copied, "copy encoded bytes")
                let nals = try split(bytes, header: ps.nalUnitHeaderLength)
                if i == 0 {
                    guard isKey, nals.contains(where: { [19, 20].contains(Int(($0[0] >> 1) & 0x3f)) }) else {
                        throw Failure.message("requested IDR missing at frame \(i)")
                    }
                }
                if isKey {
                    keyframes += 1
                    for set in ps.sets { stream.append(contentsOf: [0, 0, 0, 1]); stream.append(set) }
                }
                for nal in nals { stream.append(contentsOf: [0, 0, 0, 1]); stream.append(nal) }
                if decoder == nil {
                    let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary
                    try require(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                decoderSpecification: spec, imageBufferAttributes: nil, outputCallback: nil,
                                decompressionSessionOut: &decoder), "create software decoder")
                }
                guard let decoder else { throw Failure.message("missing decoder") }
                let decoded = Decoded()
                try require(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
                    decoded.put(status: status, image: image, pts: pts)
                }, "submit decode")
                guard decoded.wait(pts: CMSampleBufferGetPresentationTimeStamp(sb)) else {
                    throw Failure.message("decode output/status/dimensions/PTS at frame \(i)")
                }
                withExtendedLifetime(pb) {}
            }
            guard samples.count == frames else { throw Failure.message("unexpected sample count \(samples.count)") }
            var c = enc.capabilities
            guard c.propertyStatuses["encode.submit"] == nil, c.propertyStatuses["encode.output"] == nil else {
                throw Failure.message("encoder reported errors: \(c.propertyStatuses)")
            }
            if let outputDirectory {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try stream.write(to: outputDirectory.appendingPathComponent("\(mode.rawValue).hevc"), options: .atomic)
            }
            c.probeOutcome = .passed; report(c)
            print("PASS: \(frames) encoded and software-decoded samples; \(keyframes) keyframes; \(stream.count) Annex-B bytes. Local encode/decode only; no device involved.")
            return 0
        } catch {
            if let error = error as? HEVCEncoder.EncoderError, let c = error.capabilities {
                report(c)
                print("\(c.probeOutcome == .unsupported ? "UNSUPPORTED" : "FAIL"): \(error)")
                return c.probeOutcome == .unsupported ? 2 : 1
            }
            print("FAIL: \(error)")
            return 1
        }
    }

    private static func report(_ c: EncoderCapabilities) {
        print("requested=\(c.requestedMode.rawValue) hardware=\(c.usingHardware.map(String.init) ?? "unknown") encoderID=\(c.encoderID ?? "unavailable") gpuRegistryID=\(c.gpuRegistryID.map(String.init) ?? "unknown") outcome=\(c.probeOutcome.rawValue)")
        for key in c.propertyStatuses.keys.sorted() { print("  \(key)=\(c.propertyStatuses[key]!)") }
    }

    private static func require(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure.message("\(operation): OSStatus \(status)") }
    }
    private enum Failure: Error { case message(String) }

    private static func split(_ bytes: Data, header: Int) throws -> [Data] {
        guard (1...4).contains(header) else { throw Failure.message("invalid NAL header length") }
        var offset = 0, nals: [Data] = []
        while offset < bytes.count {
            guard bytes.count - offset >= header else { throw Failure.message("truncated NAL length") }
            var length = 0
            for byte in bytes[offset..<(offset + header)] { length = length * 256 + Int(byte) }
            offset += header
            guard length >= 2, length <= bytes.count - offset else { throw Failure.message("invalid NAL length") }
            nals.append(bytes.subdata(in: offset..<(offset + length))); offset += length
        }
        guard !nals.isEmpty else { throw Failure.message("no NALs") }
        return nals
    }

    private static func frame(index: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pb) == kCVReturnSuccess,
              let pb, CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            memset(y, 96, stride * 720)
            for row in 0..<720 { memset(y.advanced(by: row * stride + (index * 8) % 1200), 235, 80) }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) { memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * 360) }
        return pb
    }

    /// One submitted frame at a time; retain at most one encoded sample for the consumer.
    private final class Samples {
        private let lock = NSLock(), ready = DispatchSemaphore(value: 0)
        private var sample: CMSampleBuffer?
        private var total = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return total }
        func put(_ sb: CMSampleBuffer) { lock.lock(); sample = sb; total += 1; lock.unlock(); ready.signal() }
        func take(timeout: TimeInterval) -> CMSampleBuffer? {
            guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }; defer { sample = nil }; return sample
        }
    }
    private final class Decoded {
        private let lock = NSLock(), ready = DispatchSemaphore(value: 0)
        private var ok = false, pts = CMTime.invalid
        func put(status: OSStatus, image: CVImageBuffer?, pts: CMTime) {
            lock.lock()
            ok = status == noErr && image.map { CVPixelBufferGetWidth($0) == 1280 && CVPixelBufferGetHeight($0) == 720 } == true
            self.pts = pts
            lock.unlock(); ready.signal()
        }
        func wait(pts expected: CMTime) -> Bool {
            guard ready.wait(timeout: .now() + 1) == .success else { return false }
            lock.lock(); defer { lock.unlock() }; return ok && CMTimeCompare(pts, expected) == 0
        }
    }
}
