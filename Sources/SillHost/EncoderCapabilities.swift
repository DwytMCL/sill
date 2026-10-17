import Foundation

/// `softwareRequested` is the explicit opt-in for Macs whose VideoToolbox never confirms a software
/// backend (`UsingHardwareAcceleratedVideoEncoder` unsupported): the hardware is disabled in the
/// request, an unreadable backend is accepted as unknown, and a readback of true still fails.
package enum EncoderMode: String, Sendable { case auto, hardware, software, softwareRequested = "software-requested" }
package enum EncoderProbeOutcome: String, Sendable { case notRun, passed, failed, timedOut, unsupported }

/// Requested policy and observed VT selection are deliberately separate. A prepared session has
/// not yet passed a frame/decode test; unavailable readback is unknown, never hardware proof.
package struct EncoderCapabilities: Sendable {
    package var requestedMode: EncoderMode
    package var usingHardware: Bool?
    package var encoderID: String?
    package var gpuRegistryID: UInt64?
    package var propertyStatuses: [String: Int32]
    package var probeOutcome: EncoderProbeOutcome
}
