import Foundation

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
    precondition(condition(), reason); assertions += 1
}
let standard = HostConfig.standard
check(standard.encoderMode == .auto, "Existing callers keep auto")
for mode in [EncoderMode.auto, .hardware, .software, .softwareRequested] {
    var config = standard; config.encoderMode = mode
    check(config.validated().encoderMode == mode, "Validation retains local selection")
    let policy = EncoderSelectionPolicy(configured: mode, syntheticSoftwareOnly: false)
    var probes = 0
    // Real coordinator startup and throughput calls use this gate; all recovery entry points
    // additionally require allowsHardwareRecovery before queuing or accepting a return.
    for _ in 0..<4 { _ = policy.hardwareProbe { probes += 1; return true } }
    check(probes == (mode == .auto ? 4 : 0), "Forced modes never execute probe closures")
    check(policy.allowsHardwareRecovery == (mode == .auto), "Only auto can fall back/recheck/return")
    check(policy.sessionMode(fallback: false) == mode, "Stream constructor receives intent")
    check(policy.sessionMode(fallback: true) == (mode == .auto ? .software : mode), "Hardware cannot silently fall back")
    check(policy.stopsOnHang == (mode == .hardware), "Required hardware stops instead of CPU recovery")
}
let legacy = EncoderSelectionPolicy(configured: .auto, syntheticSoftwareOnly: true)
check(legacy.softwareOnly && !legacy.allowsHardwareRecovery, "Legacy synthetic-only hook stays isolated")
let strict = EncoderSelectionPolicy(configured: .hardware, syntheticSoftwareOnly: true)
check(strict.mode == .hardware && strict.stopsOnHang, "Explicit hardware cannot be weakened by test override")
let defaultMode = try EncoderSelectionPolicy.requestedMode(arguments: ["SillHost"])
check(defaultMode == nil, "Absent explicit mode keeps legacy three-mode self-test")
check((defaultMode ?? .auto) == standard.encoderMode, "Absent explicit mode keeps host auto")
for mode in [EncoderMode.auto, .hardware, .software, .softwareRequested] {
    let parsed = try EncoderSelectionPolicy.requestedMode(arguments: ["SillHost", "--encoder-mode=\(mode.rawValue)"])
    check(parsed == mode, "Explicit CLI mode also limits self-test to that mode")
}
for args in [["--encoder-mode"], ["--encoder-mode=invalid"], ["--encoder-mode="], ["--encoder-mode=auto", "--encoder-mode=software"]] {
    do { _ = try EncoderSelectionPolicy.requestedMode(arguments: args); preconditionFailure("Invalid CLI accepted") }
    catch { assertions += 1 }
}
var snapshot = HostStatusSnapshot()
func capabilities(_ observed: Bool?) -> EncoderCapabilities {
    EncoderCapabilities(requestedMode: .auto, usingHardware: observed, encoderID: nil, gpuRegistryID: nil,
                        propertyStatuses: [:], probeOutcome: .notRun)
}
check(!snapshot.hardwareEncoder, "No snapshot never means hardware")
snapshot.encoderCapabilities = capabilities(nil)
check(!snapshot.hardwareEncoder, "Unreadable backend remains unknown")
snapshot.encoderCapabilities = capabilities(false)
check(!snapshot.hardwareEncoder, "Software readback cannot claim hardware")
snapshot.encoderCapabilities = capabilities(true)
check(!snapshot.hardwareEncoder, "An idle probe does not claim a live hardware stream")
snapshot.stream = HostStatusSnapshot.Stream(kind: .desktop, title: "fixture", width: 1280, height: 720, fps: 30,
                                             mbps: 4, onVirtualDisplay: false, softwareEncoder: false)
check(snapshot.hardwareEncoder, "Only true readback permits hardware status")
var changed = snapshot
changed.encoderCapabilities?.propertyStatuses["prepare"] = -1
check(changed != snapshot, "Status equality preserves operation failures")
let requested = EncoderSelectionPolicy(configured: .softwareRequested, syntheticSoftwareOnly: false)
check(requested.softwareOnly && !requested.allowsHardwareRecovery && !requested.stopsOnHang, "Opt-in is software-only with no hardware recovery")
check(requested.sessionMode(fallback: true) == .softwareRequested, "Opt-in never turns into another mode")
check(EncoderMode(rawValue: "software-requested") == .softwareRequested, "CLI spelling")
print("encoder-selection: \(assertions) policy/CLI/status checks passed; no VT or host runtime")
