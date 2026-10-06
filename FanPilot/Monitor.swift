import Foundation
import Observation
import FanCore

actor HardwareMonitor {
    private let device: AppleSMC
    private let discovery: MachineDiscovery
    private let fanRanges: [Int: (minimum: Double, maximum: Double)]
    init() throws {
        device = try AppleSMC(); discovery = try FanDiscovery.inspect(device: device)
        var ranges: [Int: (minimum: Double, maximum: Double)] = [:]
        for fan in discovery.fans {
            guard let minimum = try? SMCCodec.number(device.read(fan.minimumKey)),
                  let maximum = try? SMCCodec.number(device.read(fan.maximumKey)) else { continue }
            ranges[fan.index] = (minimum, maximum)
        }
        fanRanges = ranges
    }
    func snapshot(sensorKeys: Set<String>? = nil) -> HelperState {
        var result = FanSnapshotReader().snapshot(device: device, discovery: discovery, cachedRanges: fanRanges)
        result.sensors = discovery.sensors
            .filter { sensor in sensorKeys.map { $0.contains(sensor.key) } ?? true }
            .compactMap { sensor -> SensorReading? in
                guard let value = try? device.read(sensor.key), let c = try? SMCCodec.number(value), SensorDiscovery.valid(c) else { return nil }
                return SensorReading(key: sensor.key, temperature: c, kind: sensor.kind)
            }
        return result
    }
    func diagnostics() -> MachineDiscovery { discovery }
    func thermalUnlockValue() -> Double? { try? SMCCodec.number(device.read("Ftst")) }
}

@MainActor @Observable final class Monitor {
    var state = HelperState()
    var menuTemperature: Int?
    /// The hottest-sensor reading eased over a few seconds: it rises quickly, falls slowly, and ignores
    /// one-second spikes, so the UI shows a calm number. Control logic never uses this.
    var displayTemperature: Double?
    var menuRPM: Int?
    var error: String?
    var connected = false
    var sensorHistory: [String: [Double]] = [:]
    private var reader: HardwareMonitor?
    private var polling: Task<Void, Never>?
    private var cachedSensors: [String: SensorReading] = [:]
    private var lastMenuRefresh: Date?
    private var recentTemperatures: [Double] = []

    func start() {
        guard polling == nil else { return }
        polling = Task {
            do {
                let reader = try await Task.detached(priority: .utility) { try HardwareMonitor() }.value
                self.reader = reader; connected = true
                var lastFullSensorSample: Date?
                while !Task.isCancelled {
                    let now = Date()
                    let scanAllSensors = lastFullSensorSample.map { now.timeIntervalSince($0) >= 5 } ?? true
                    let fastKeys = Set(cachedSensors.values
                        .filter { $0.kind != .other }
                        .sorted { $0.temperature > $1.temperature }
                        .prefix(5)
                        .map(\.key))
                    let sampled = await reader.snapshot(sensorKeys: scanAllSensors ? nil : fastKeys)
                    if scanAllSensors { lastFullSensorSample = now }
                    for sensor in sampled.sensors { cachedSensors[sensor.key] = sensor }
                    let refreshedSensors = sampled.sensors
                    var updatedHistory = sensorHistory
                    for sensor in refreshedSensors {
                        var values = updatedHistory[sensor.key, default: []]
                        values.append(sensor.temperature)
                        if values.count > 48 { values.removeFirst(values.count - 48) }
                        updatedHistory[sensor.key] = values
                    }
                    sensorHistory = updatedHistory
                    var next = sampled
                    next.sensors = cachedSensors.values.sorted { $0.key < $1.key }
                    if let raw = next.controlTemperature {
                        // Median of the last few seconds ignores one-second spikes; the easing and the
                        // half-degree threshold keep the number (and the gauge) from re-animating constantly.
                        recentTemperatures.append(raw)
                        if recentTemperatures.count > 7 { recentTemperatures.removeFirst() }
                        let median = recentTemperatures.sorted()[recentTemperatures.count / 2]
                        let eased = displayTemperature.map { $0 + (median - $0) * (median > $0 ? 0.4 : 0.15) } ?? median
                        if displayTemperature.map({ abs($0 - eased) >= 0.5 }) ?? true { displayTemperature = eased }
                    }
                    let nextMenuTemperature = displayTemperature.map { Int($0.rounded()) }
                    let nextMenuRPM = next.fans.max(by: { $0.rpm < $1.rpm }).map { Int($0.rpm.rounded()) }
                    // Each label change redraws the status item, which dominated idle CPU; refresh the
                    // menu bar text every few seconds unless the temperature moves noticeably.
                    let bigJump: Bool
                    if let old = menuTemperature, let new = nextMenuTemperature { bigJump = abs(old - new) >= 3 }
                    else { bigJump = menuTemperature != nextMenuTemperature }
                    if bigJump || lastMenuRefresh.map({ now.timeIntervalSince($0) >= 3 }) ?? true {
                        lastMenuRefresh = now
                        if menuTemperature != nextMenuTemperature { menuTemperature = nextMenuTemperature }
                        if menuRPM != nextMenuRPM { menuRPM = nextMenuRPM }
                    }
                    state = next; error = nil
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch { self.error = error.localizedDescription; connected = false }
        }
    }
    func diagnosticsData() async throws -> Data {
        guard let reader else { throw SMCError.unavailable }
        let machine = await reader.diagnostics()
        let liveState = await reader.snapshot()
        let ftst = await reader.thermalUnlockValue()
        let currentFans = Dictionary(uniqueKeysWithValues: liveState.fans.map { ($0.id, $0) })
        let report: [String: Any] = [
            "version": "1.0", "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "modelIdentifier": sysctlModel(), "chip": cpuBrand(), "fanless": machine.fanless,
            "hasFtst": machine.hasFtst, "ftst": ftst.map { $0 as Any } ?? NSNull(),
            "fans": machine.fans.map { fan -> [String: Any] in
                let live = currentFans[fan.index]
                let rpm: Any = live.map { $0.rpm as Any } ?? NSNull()
                let target: Any = live.map { $0.target as Any } ?? NSNull()
                let minimum: Any = live.map { $0.minimum as Any } ?? NSNull()
                let maximum: Any = live.map { $0.maximum as Any } ?? NSNull()
                let manual: Any = live.map { $0.manual as Any } ?? NSNull()
                return ["index": fan.index, "name": fan.name, "rpmKey": fan.rpmKey, "targetKey": fan.targetKey,
                        "minimumKey": fan.minimumKey, "maximumKey": fan.maximumKey, "modeKey": fan.modeKey,
                        "rpm": rpm, "target": target, "minimum": minimum,
                        "maximum": maximum, "manual": manual]
            },
            "sensors": liveState.sensors.map { ["key": $0.key, "temperature": $0.temperature, "kind": $0.kind.rawValue] }
        ]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
    private func sysctlModel() -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); p.arguments = ["-n", "hw.model"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func cpuBrand() -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); p.arguments = ["-n", "machdep.cpu.brand_string"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
