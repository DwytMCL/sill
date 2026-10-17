import Foundation

/// Coordinator selection only. Observed backend identity always comes from VT readback.
package struct EncoderSelectionPolicy: Sendable {
    let mode: EncoderMode
    init(configured: EncoderMode, syntheticSoftwareOnly: Bool) {
        mode = configured == .auto && syntheticSoftwareOnly ? .software : configured
    }
    var softwareOnly: Bool { mode == .software || mode == .softwareRequested }
    var allowsHardwareRecovery: Bool { mode == .auto }
    var stopsOnHang: Bool { mode == .hardware }
    func sessionMode(fallback: Bool) -> EncoderMode { mode == .auto && fallback ? .software : mode }

    /// Every coordinator probe passes this gate, including callbacks from older recovery tasks.
    func hardwareProbe<T>(_ body: () -> T) -> T? {
        guard allowsHardwareRecovery else { return nil }
        return body()
    }

    /// Nil preserves the legacy all-mode self-test; the host's default remains auto.
    package static func requestedMode(arguments: [String]) throws -> EncoderMode? {
        let flags = arguments.filter { $0 == "--encoder-mode" || $0.hasPrefix("--encoder-mode=") }
        guard !flags.isEmpty else { return nil }
        guard flags.count == 1, let flag = flags.first, flag.hasPrefix("--encoder-mode="),
              let mode = EncoderMode(rawValue: String(flag.dropFirst("--encoder-mode=".count))) else {
            throw NSError(domain: "Sill.EncoderMode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Use --encoder-mode=auto|hardware|software|software-requested once."])
        }
        return mode
    }
}
