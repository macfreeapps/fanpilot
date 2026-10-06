import Foundation

public actor FanController {
    private let device: any SMCDevice
    private let fans: [FanDescriptor]
    private let hasFtst: Bool
    private let retryInterval: TimeInterval
    private let retryCount: Int
    private let onUnlockIntent: (@Sendable () throws -> Void)?
    private var ownsFtst = false
    private var manualFans: Set<Int> = []

    public init(device: any SMCDevice, fans: [FanDescriptor], hasFtst: Bool, retryInterval: TimeInterval = 0.1, retryCount: Int = 100, onUnlockIntent: (@Sendable () throws -> Void)? = nil) {
        self.device = device; self.fans = fans; self.hasFtst = hasFtst
        self.retryInterval = max(0, retryInterval); self.retryCount = max(1, retryCount)
        self.onUnlockIntent = onUnlockIntent
    }
    public func engageManual(_ fan: FanDescriptor) throws {
        do {
            try write(1, key: fan.modeKey)
            if try manualModeIsEngaged(fan) { return }
        } catch SMCError.badCommand where hasFtst {
            // M3/M4 firmware may reject writes until Ftst is set.
        }

        guard hasFtst else { throw SMCError.malformed(fan.modeKey) }
        try onUnlockIntent?()
        ownsFtst = true
        try write(1, key: "Ftst")
        for _ in 0..<retryCount {
            if retryInterval > 0 { Thread.sleep(forTimeInterval: retryInterval) }
            do {
                try write(1, key: fan.modeKey)
                if try manualModeIsEngaged(fan) { return }
            } catch SMCError.badCommand {
                continue
            }
        }
        throw SMCError.badCommand
    }
    public func setTarget(_ rpm: Double, for fan: FanDescriptor) throws {
        let minimum = try SMCCodec.number(device.read(fan.minimumKey))
        let maximum = try SMCCodec.number(device.read(fan.maximumKey))
        guard minimum <= maximum else { throw SMCError.malformed("fan range") }
        let target = Swift.min(maximum, Swift.max(minimum, rpm))
        let existing = (try? SMCCodec.number(device.read(fan.targetKey))) ?? 0
        guard abs(existing - target) >= 50 else { return }
        let info = try device.keyInfo(fan.targetKey)
        try device.write(fan.targetKey, bytes: SMCCodec.bytes(target, type: info.type, size: info.size))
        for attempt in 0..<min(retryCount, 10) {
            let readback = try SMCCodec.number(device.read(fan.targetKey))
            if abs(readback - target) < 50 { return }
            if attempt + 1 < min(retryCount, 10), retryInterval > 0 { Thread.sleep(forTimeInterval: retryInterval) }
        }
        throw SMCError.malformed("target readback")
    }
    public func release(_ fan: FanDescriptor) throws {
        try write(0, key: fan.modeKey)
        var released = false
        for attempt in 0..<retryCount {
            let mode = try SMCCodec.number(device.read(fan.modeKey))
            // Some Apple Silicon firmware reports 3 after accepting the automatic-mode write.
            if mode == 0 || mode == 3 { released = true; break }
            guard mode == 1 else { throw SMCError.malformed("unexpected fan mode \(mode) for \(fan.modeKey)") }
            if attempt + 1 < retryCount, retryInterval > 0 { Thread.sleep(forTimeInterval: retryInterval) }
        }
        guard released else { throw SMCError.malformed(fan.modeKey) }
        manualFans.remove(fan.index)
        if manualFans.isEmpty, ownsFtst, hasFtst, (try? SMCCodec.number(device.read("Ftst"))) == 1 {
            try write(0, key: "Ftst")
            ownsFtst = false
        }
    }
    public func releaseAll(clearFtst: Bool = false) throws {
        for fan in fans {
            let mode = try SMCCodec.number(device.read(fan.modeKey))
            if manualFans.contains(fan.index) || mode == 1 { try release(fan) }
            else if mode != 0 && mode != 3 { throw SMCError.malformed("unexpected mode value for \(fan.modeKey)") }
        }
        if clearFtst, hasFtst {
            let thermalMode = try SMCCodec.number(device.read("Ftst"))
            if thermalMode == 1 { try write(0, key: "Ftst") }
            else if thermalMode != 0 { throw SMCError.malformed("Ftst mode value") }
            ownsFtst = false
        }
    }
    public func ownsThermalUnlock() -> Bool { ownsFtst }
    private func write(_ value: Double, key: String) throws {
        guard FanWritePolicy.permits(key, fanCount: fans.count) else { throw SMCError.malformed("disallowed write key \(key)") }
        let info = try device.keyInfo(key)
        try device.write(key, bytes: SMCCodec.bytes(value, type: info.type, size: info.size))
    }
    private func manualModeIsEngaged(_ fan: FanDescriptor) throws -> Bool {
        let mode = try SMCCodec.number(device.read(fan.modeKey))
        guard mode == 0 || mode == 1 || mode == 3 else { throw SMCError.malformed("unexpected fan mode \(mode) for \(fan.modeKey)") }
        if mode == 1 { manualFans.insert(fan.index); return true }
        return false
    }
}
