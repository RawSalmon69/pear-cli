import Foundation
import IOKit

// Minimal, read-only System Management Controller client. Opens a user client
// on the AppleSMC IOService and reads numeric keys (temperatures, fan speeds).
// It NEVER writes — no fan control, no key mutation. On modern macOS these
// reads need neither root nor a special entitlement as long as the app is not
// sandboxed (PearCompanion is not); if the open fails the whole thing
// soft-fails to nil and the Sensors section simply does not appear.
//
// Adapted from Stats (MIT) — `SMC/smc.swift` (read path only).

private enum SMCParamStruct {
    static let kernelIndex: UInt8 = 2
    static let readBytes: UInt8 = 5
    static let readKeyInfo: UInt8 = 9
}

private struct SMCKeyData {
    // 32-byte payload, mirrored as a fixed tuple to match the kernel struct.
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCValue {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes = [UInt8](repeating: 0, count: 32)
}

private func fourCharCode(_ str: String) -> UInt32 {
    str.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func typeString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

final class SMCConnection {
    private var conn: io_connect_t = 0

    /// Opens the AppleSMC user client, or returns nil if unavailable.
    init?() {
        let matching = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            == kIOReturnSuccess else { return nil }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return nil }
        let result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard result == kIOReturnSuccess, conn != 0 else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    /// Reads and scales a numeric SMC key, or nil if it does not exist / is
    /// all-zero / has an unsupported type.
    func value(_ key: String) -> Double? {
        var val = SMCValue(key: key)
        guard read(&val) == kIOReturnSuccess, val.dataSize > 0 else { return nil }
        if val.bytes.first(where: { $0 != 0 }) == nil { return nil }
        return decode(val)
    }

    // MARK: - Decoding (subset of SMC types relevant to temps/fans/power)

    private func decode(_ val: SMCValue) -> Double? {
        let b = val.bytes
        func u16() -> Double { Double(UInt16(b[0]) << 8 | UInt16(b[1])) }
        func s16() -> Double { Double(Int(b[0]) * 256 + Int(b[1])) }
        switch val.dataType {
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "flt ":
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2": return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        case "sp1e": return u16() / 16384
        case "sp3c": return u16() / 4096
        case "sp4b": return u16() / 2048
        case "sp5a": return u16() / 1024
        case "sp69": return u16() / 512
        case "sp78": return s16() / 256
        case "sp87": return s16() / 128
        case "sp96": return s16() / 64
        case "spa5": return u16() / 32
        case "spb4": return s16() / 16
        case "spf0": return s16()
        default: return nil
        }
    }

    // MARK: - Low-level read

    private func read(_ val: inout SMCValue) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCharCode(val.key)
        input.data8 = SMCParamStruct.readKeyInfo

        var status = call(&input, &output)
        guard status == kIOReturnSuccess else { return status }

        val.dataSize = UInt32(output.keyInfo.dataSize)
        val.dataType = typeString(output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCParamStruct.readBytes

        status = call(&input, &output)
        guard status == kIOReturnSuccess else { return status }

        withUnsafeBytes(of: output.bytes) { src in
            let n = min(Int(val.dataSize), val.bytes.count)
            for i in 0..<n { val.bytes[i] = src[i] }
        }
        return kIOReturnSuccess
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(
            conn, UInt32(SMCParamStruct.kernelIndex), &input, inputSize, &output, &outputSize)
    }
}

// MARK: - Sensor sampling

/// The SMC keys that responded on this machine, resolved once so later ticks
/// read only what exists (an SMC read is two syscalls; probing the whole
/// candidate list every 2 s would be wasteful).
struct ResolvedSensorKeys: Sendable {
    var cpu: [String]
    var gpu: [String]
    var battery: [String]
    var fans: [String]

    var isEmpty: Bool { cpu.isEmpty && gpu.isEmpty && battery.isEmpty && fans.isEmpty }
}

// Candidate temperature keys spanning Intel and Apple Silicon M1–M4. Probing a
// broad union and keeping only what answers is exactly Stats' approach: chips
// expose different keys (Tp09/Tg05… vary by generation) and there is no error
// when a key is absent. Adapted from Stats (MIT) — `Modules/Sensors/values.swift`.
enum SensorSampler {
    private static let cpuCandidates = [
        // Intel die / proximity
        "TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCXC",
        // Apple Silicon performance cores (M1–M4 variants)
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "Tp0T", "Tp0f", "Tp0j", "Tp0V", "Tp0Y", "Tp0e",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        // Apple Silicon efficiency cores
        "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H",
    ]
    private static let gpuCandidates = [
        "TG0P", "TG0D",  // Intel
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k",  // Apple Silicon
    ]
    private static let batteryCandidates = ["TB0T", "TB1T", "TB2T"]

    /// Probes candidates once, keeping keys that read back a plausible value.
    static func resolve(_ smc: SMCConnection) -> ResolvedSensorKeys {
        func working(_ keys: [String]) -> [String] {
            keys.filter { key in
                guard let v = smc.value(key) else { return false }
                return v > 0 && v <= 120
            }
        }

        var fans: [String] = []
        if let count = smc.value("FNum"), count > 0 {
            for i in 0..<Int(count) {
                let key = "F\(i)Ac"
                if smc.value(key) != nil { fans.append(key) }
            }
        }

        return ResolvedSensorKeys(
            cpu: working(cpuCandidates),
            gpu: working(gpuCandidates),
            battery: working(batteryCandidates),
            fans: fans)
    }

    /// Reads the resolved keys into a snapshot. Temperatures collapse to the
    /// hottest reading per group so the popover stays compact. Returns nil when
    /// nothing usable was read.
    static func read(_ smc: SMCConnection, keys: ResolvedSensorKeys) -> SensorSample? {
        func hottest(_ list: [String], label: String, id: String) -> SensorReading? {
            let values = list.compactMap { smc.value($0) }.filter { $0 > 0 && $0 <= 120 }
            guard let max = values.max() else { return nil }
            return SensorReading(id: id, label: label, value: max, unit: .celsius)
        }

        var temps: [SensorReading] = []
        if let r = hottest(keys.cpu, label: "CPU", id: "cpu") { temps.append(r) }
        if let r = hottest(keys.gpu, label: "GPU", id: "gpu") { temps.append(r) }
        if let r = hottest(keys.battery, label: "Battery", id: "batt") { temps.append(r) }

        var fans: [SensorReading] = []
        for (i, key) in keys.fans.enumerated() {
            if let rpm = smc.value(key), rpm >= 0 {
                fans.append(SensorReading(
                    id: key, label: keys.fans.count > 1 ? "Fan \(i + 1)" : "Fan",
                    value: rpm, unit: .rpm))
            }
        }

        if temps.isEmpty && fans.isEmpty { return nil }
        return SensorSample(temperatures: temps, fans: fans)
    }
}
