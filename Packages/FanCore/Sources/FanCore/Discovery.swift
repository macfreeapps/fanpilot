import Foundation

public enum SensorDiscovery {
    public static func classify(_ key: String) -> SensorReading.Kind {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
        if key.hasPrefix("Tg") { return .gpu }
        return .other
    }
    public static func valid(_ celsius: Double) -> Bool { celsius.isFinite && (5...130).contains(celsius) }
}

public struct FanDescriptor: Sendable {
    public let index: Int
    public let name: String
    public let rpmKey: String
    public let targetKey: String
    public let minimumKey: String
    public let maximumKey: String
    public let modeKey: String
    public let modeIsLowercase: Bool
}

public struct MachineDiscovery: Sendable {
    public let fans: [FanDescriptor]
    public let hasFtst: Bool
    public let sensors: [SensorReading]
    public let fanless: Bool
    public let controlTemperature: Double?
}

public enum FanDiscovery {
    public static func inspect(device: any SMCDevice) throws -> MachineDiscovery {
        let count = (try? SMCCodec.number(device.read("FNum"))) ?? 0
        var fans: [FanDescriptor] = []
        for index in 0..<min(16, Int(count)) {
            let upper = "F\(index)Md", lower = "F\(index)md"
            let mode = try modeKey(upper: upper, lower: lower, device: device)
            guard let mode else { continue }
            let labels = Int(count) == 2 ? ["Left", "Right"] : []
            let idKey = "F\(index)ID"
            let id = try? device.read(idKey)
            let hardwareName = id.flatMap { String(bytes: $0.bytes.prefix { $0 != 0 }, encoding: .macOSRoman) }
            fans.append(FanDescriptor(index: index, name: hardwareName?.isEmpty == false ? hardwareName! : (labels.isEmpty ? "Fan \(index + 1)" : labels[index]), rpmKey: "F\(index)Ac", targetKey: "F\(index)Tg", minimumKey: "F\(index)Mn", maximumKey: "F\(index)Mx", modeKey: mode, modeIsLowercase: mode == lower))
        }
        let hasFtst = (try? device.keyInfo("Ftst")) != nil
        let countResult = (try? device.read("#KEY")).flatMap { try? UInt32(SMCCodec.number($0)) } ?? 0
        var sensors: [SensorReading] = []
        for index in 0..<min(countResult, 8192) {
            // Keep every temperature key by type, not by its reading right now: idle cores (for example
            // the second performance cluster) report invalid values while powered off and valid ones
            // under load. Validity is applied to each sample by whoever reads the sensor. The stored
            // temperature is only a discovery-time reading, 0 when it was not valid.
            guard let key = try? device.key(at: index), key.hasPrefix("T"),
                  let info = try? device.keyInfo(key), ["flt ", "sp78"].contains(info.type) else { continue }
            let reading = (try? SMCCodec.number(device.read(key))).flatMap { SensorDiscovery.valid($0) ? $0 : nil }
            sensors.append(SensorReading(key: key, temperature: reading ?? 0, kind: SensorDiscovery.classify(key)))
        }
        return MachineDiscovery(fans: fans, hasFtst: hasFtst, sensors: sensors, fanless: fans.isEmpty, controlTemperature: sensors.filter { $0.kind != .other && SensorDiscovery.valid($0.temperature) }.map(\.temperature).max())
    }

    private static func modeKey(upper: String, lower: String, device: any SMCDevice) throws -> String? {
        do { _ = try device.keyInfo(upper); return upper }
        catch SMCError.notFound {
            do { _ = try device.keyInfo(lower); return lower }
            catch SMCError.notFound { return nil }
        }
    }
}

public struct FanSnapshotReader {
    public init() {}
    public func snapshot(device: any SMCDevice, discovery: MachineDiscovery, cachedRanges: [Int: (minimum: Double, maximum: Double)] = [:]) -> HelperState {
        var state = HelperState()
        state.sensors = discovery.sensors
        state.fans = discovery.fans.compactMap { fan in
            guard let rpm = try? SMCCodec.number(device.read(fan.rpmKey)),
                  let target = try? SMCCodec.number(device.read(fan.targetKey)) else { return nil }
            let minimum: Double
            let maximum: Double
            if let range = cachedRanges[fan.index] {
                minimum = range.minimum; maximum = range.maximum
            } else {
                guard let readMinimum = try? SMCCodec.number(device.read(fan.minimumKey)),
                      let readMaximum = try? SMCCodec.number(device.read(fan.maximumKey)) else { return nil }
                minimum = readMinimum; maximum = readMaximum
            }
            let manual = ((try? SMCCodec.number(device.read(fan.modeKey))) ?? 0) == 1
            return FanReading(id: fan.index, name: fan.name, rpm: rpm, target: target, minimum: minimum, maximum: maximum, manual: manual)
        }
        return state
    }
}

public enum FanWritePolicy {
    public static func permits(_ key: String, fanCount: Int) -> Bool {
        if key == "Ftst" { return true }
        for i in 0..<max(0, fanCount) where key == "F\(i)Md" || key == "F\(i)md" || key == "F\(i)Tg" { return true }
        return false
    }
}

public enum FanOwnership {
    /// Returns true when the observed SMC state indicates another manual controller.
    /// Mode 3 is the known firmware/thermal-manager automatic state on supported Macs.
    public static func hasExternalController(modes: [Double], thermalUnlock: Double?) throws -> Bool {
        for mode in modes {
            if mode == 1 { return true }
            guard mode == 0 || mode == 3 else { throw SMCError.malformed("unknown fan mode \(mode)") }
        }
        if let thermalUnlock {
            if thermalUnlock == 1 { return true }
            guard thermalUnlock == 0 else { throw SMCError.malformed("unknown Ftst mode \(thermalUnlock)") }
        }
        return false
    }
}
