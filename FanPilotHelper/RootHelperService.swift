import Foundation
import FanCore
import Security
import os
import IOKit.pwr_mgt

private struct PersistedState: Codable {
    var dirty = false
    var weSetFtst = false
}

private final class ControllerResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ result: Result<Value, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func load() throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw SMCError.malformed("fan controller returned no result") }
        return try result.get()
    }
}

/// Shared between the control queue (which beats) and an independent watchdog queue (which checks).
private final class ControlLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = Date()
    private var manual = false
    func beat() { lock.lock(); lastBeat = Date(); lock.unlock() }
    func setManual(_ value: Bool) { lock.lock(); manual = value; lastBeat = Date(); lock.unlock() }
    func stalled(after seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return manual && Date().timeIntervalSince(lastBeat) > seconds
    }
}

final class RootHelperService: NSObject, NSXPCListenerDelegate, FanHelperProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.fanpilot", category: "control")
    private let queue = DispatchQueue(label: "com.fanpilot.control", qos: .userInitiated)
    private var device: AppleSMC?
    private var machine: MachineDiscovery?
    private var fanController: FanController?
    private var current = HelperState()
    private var config = DailyConfig()
    private var dailyEngine: DailyCurveEngine?
    private var persist = PersistedState()
    private var lastHeartbeat = Date()
    private var heartbeatTimer: DispatchSourceTimer?
    private var controlTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerNotificationPort: IONotificationPortRef?
    private var powerRootPort: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var badSensorCount = 0
    private var conflict = false
    private var lastRestoreErrorLogged: String?
    private var lastRecoveryAttempt = Date.distantPast
    private let liveness = ControlLiveness()
    private let livenessQueue = DispatchQueue(label: "com.fanpilot.liveness", qos: .userInitiated)
    private var livenessTimer: DispatchSourceTimer?
    private static let clientRequirement = "identifier \"com.fanpilot.app\" and anchor apple generic and certificate leaf[subject.OU] = \"YUVK5PXJXH\""
    private let stateURL = URL(fileURLWithPath: "/Library/Application Support/FanPilot/helper-state.json")

    override init() {
        super.init()
        queue.sync { startup() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Enforced by the XPC runtime against the connecting process's audit token, so it cannot be
        // raced by PID reuse the way a lookup by processIdentifier can.
        connection.setCodeSigningRequirement(Self.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            guard let helper = self else { return }
            helper.queue.async { [weak helper] in
                guard let helper, helper.current.mode != .normal else { return }
                helper.logger.error("App connection closed; restoring system fan control")
                helper.failSafe("app connection closed")
            }
        }
        connection.resume()
        return true
    }

    func version(reply: @escaping @Sendable (String) -> Void) { reply("1.0") }
    func heartbeat() { queue.async { self.lastHeartbeat = Date() } }
    func snapshot(reply: @escaping @Sendable (Data) -> Void) {
        queue.async { reply((try? JSONEncoder().encode(self.makeSnapshot())) ?? Data()) }
    }
    func setMode(_ raw: Int, dailyConfig: Data, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async {
            guard let mode = FanMode(rawValue: raw), let config = try? JSONDecoder().decode(DailyConfig.self, from: dailyConfig) else { reply(false, "Invalid fan mode or settings"); return }
            // A repeat of the active mode with unchanged settings is a no-op, not a new transition
            // (which would reset the Daily engine and re-run the ownership checks).
            let validated = config.validated()
            let repeatRequest = mode != .normal && mode == self.current.mode && validated == self.config
            self.config = validated
            if repeatRequest { reply(true, nil); return }
            do { try self.transition(to: mode); reply(true, nil) }
            catch {
                let message = error.localizedDescription
                self.logger.error("Mode change failed: \(message, privacy: .public)")
                // Never leave a half-engaged state (for example one fan manual, one automatic).
                if self.current.mode != .normal { self.failSafe("mode change failed") }
                self.current.lastError = message
                reply(false, message)
            }
        }
    }
    func restoreSystemControl(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do { try self.restoreAll(); reply(true) }
            catch { self.recordRestoreFailure(error); reply(false) }
        }
    }
    func prepareForUninstall(reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async {
            do {
                try self.restoreAll()
                if FileManager.default.fileExists(atPath: self.stateURL.deletingLastPathComponent().path) {
                    try FileManager.default.removeItem(at: self.stateURL.deletingLastPathComponent())
                }
                reply(true, nil)
            } catch { self.current.lastError = error.localizedDescription; reply(false, error.localizedDescription) }
        }
    }

    private func startup() {
        do {
            device = try AppleSMC()
            machine = try FanDiscovery.inspect(device: device!)
        } catch { current.lastError = error.localizedDescription; logger.error("Startup failed: \(error.localizedDescription, privacy: .public)"); return }
        guard let machine, !machine.fanless, let device else { return }
        fanController = FanController(device: device, fans: machine.fans, hasFtst: machine.hasFtst, onUnlockIntent: { [weak self] in
            guard let self else { throw SMCError.unavailable }
            self.persist.weSetFtst = true
            try self.savePersisted()
        })
        persist = readPersisted()
        // Timers, signal handlers and the watchdog must start even if recovery or the ownership
        // check fails below; a failed recovery is retried from tick().
        defer { lastHeartbeat = Date(); beginTimers() }
        if persist.dirty {
            logger.notice("Recovering previously active fan control")
            do { try restoreAll() } catch { recordRestoreFailure(error) }
        } else {
            do {
                if try hasExternalController(machine, device: device) {
                    conflict = true; current.lastError = "Another fan utility may be controlling this Mac. FanPilot has not changed hardware."
                }
            } catch {
                // An unrecognized fan state: do not guess, do not write.
                conflict = true; current.lastError = "FanPilot does not recognize the current fan state (\(error.localizedDescription)) and has not changed hardware."
                logger.error("Startup ownership check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func beginTimers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                try? self?.restoreAll()
                exit(EXIT_SUCCESS)
            }
            source.resume(); signalSources.append(source)
        }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastHeartbeat) > 15, self.current.mode != .normal {
                self.failSafe("no heartbeat from FanPilot")
            }
        }
        watchdog.resume(); heartbeatTimer = watchdog
        startLivenessWatchdog()
        let control = DispatchSource.makeTimerSource(queue: queue)
        control.schedule(deadline: .now() + 1, repeating: 1)
        control.setEventHandler { [weak self] in self?.tick() }
        control.resume(); controlTimer = control
        registerPowerObserver()
    }

    /// Runs on its own queue so it still fires if the control queue is wedged (for example inside a
    /// hung SMC call). If a manual mode is active and the control loop has not run for 40 s, try to
    /// hand the fans back and then exit; launchd restarts the helper and startup recovery runs.
    private func startLivenessWatchdog() {
        guard let machine, let device else { return }
        let liveness = self.liveness
        let logger = self.logger
        let timer = DispatchSource.makeTimerSource(queue: livenessQueue)
        timer.schedule(deadline: .now() + 10, repeating: 5)
        timer.setEventHandler {
            guard liveness.stalled(after: 40) else { return }
            logger.fault("Control loop stalled while fans are manual; releasing and restarting helper")
            let release = DispatchWorkItem {
                for fan in machine.fans {
                    guard FanWritePolicy.permits(fan.modeKey, fanCount: machine.fans.count),
                          let info = try? device.keyInfo(fan.modeKey),
                          let bytes = try? SMCCodec.bytes(0, type: info.type, size: info.size) else { continue }
                    try? device.write(fan.modeKey, bytes: bytes)
                }
                if machine.hasFtst, let info = try? device.keyInfo("Ftst"), let bytes = try? SMCCodec.bytes(0, type: info.type, size: info.size) {
                    try? device.write("Ftst", bytes: bytes)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: release)
            _ = release.wait(timeout: .now() + 3)   // the SMC itself may be what is hung; never wait forever
            exit(EXIT_FAILURE)
        }
        timer.resume(); livenessTimer = timer
    }

    private func registerPowerObserver() {
        let callback: IOServiceInterestCallback = { context, _, messageType, messageArgument in
            guard let context else { return }
            let helper = Unmanaged<RootHelperService>.fromOpaque(context).takeUnretainedValue()
            helper.powerEvent(messageType, argument: messageArgument)
        }
        powerRootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerNotificationPort, callback, &powerNotifier)
        if powerRootPort != 0, let powerNotificationPort { IONotificationPortSetDispatchQueue(powerNotificationPort, queue) }
    }

    private func powerEvent(_ messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        // Values are kIOMessageCanSystemSleep, kIOMessageSystemWillSleep, and
        // kIOMessageSystemHasPoweredOn from IOKit/IOMessage.h.
        switch messageType {
        case 0xe0000270, 0xe0000280:
            if let argument { _ = IOAllowPowerChange(powerRootPort, Int(bitPattern: argument)) }
        case 0xe0000300:
            queue.async { [weak self] in self?.lastHeartbeat = Date() }   // wall-clock gap across sleep is not a dead app
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tick() }
        default: break
        }
    }

    private func transition(to mode: FanMode) throws {
        if conflict, mode != .normal, let machine, let device, (try? hasExternalController(machine, device: device)) == false {
            conflict = false; current.lastError = nil
        }
        guard !conflict, let machine, let device else { throw NSError(domain: "FanPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: current.lastError ?? "Fan control is unavailable"]) }
        if mode == .normal { try restoreAll(); return }
        if current.mode == .normal {
            if try hasExternalController(machine, device: device) {
                conflict = true
                current.lastError = "Another fan utility may be controlling this Mac. FanPilot has not changed hardware."
                throw NSError(domain: "FanPilot", code: 3, userInfo: [NSLocalizedDescriptionKey: current.lastError!])
            }
        }
        try markDirty()
        liveness.setManual(true)
        current.mode = mode; current.lastError = nil; badSensorCount = 0
        dailyEngine = mode == .daily ? DailyCurveEngine(config: config) : nil
        if mode == .turbo {
            for fan in machine.fans { try engage(fan); let range = try fanRange(fan); try setTarget(fan, rpm: range.maximum) }
            current.phase = "Turbo · maximum cooling"
        } else {
            let hasManualFan = machine.fans.contains { ((try? Self.number(device, $0.modeKey)) ?? 0) == 1 }
            if hasManualFan {
                let samples = try dailyFanSamples(machine)
                var engine = DailyCurveEngine(config: config)
                engine.adoptManualControl(temperature: try controlTemperature(device, machine), fans: samples)
                let command = engine.tick(temperature: try controlTemperature(device, machine), fans: samples)
                dailyEngine = engine
                try executeDailyCommand(command, machine: machine)
                current.phase = "Daily · actively cooling"
            } else { current.phase = "Daily · system controlled" }
        }
        current.fans = FanSnapshotReader().snapshot(device: device, discovery: machine).fans
    }

    private func tick() {
        liveness.beat()
        guard let machine, let device else { return }
        if current.mode == .normal {
            // A recovery or restore that failed earlier leaves persisted intent behind; keep retrying
            // rather than waiting for the next request.
            if persist.dirty, !conflict, Date().timeIntervalSince(lastRecoveryAttempt) >= 5 {
                lastRecoveryAttempt = Date()
                do { try restoreAll() } catch { recordRestoreFailure(error) }
            }
            return
        }
        guard !conflict else { return }
        do {
            if current.mode == .daily {
                try tickDaily(machine)
            } else {
                let temp = try controlTemperature(device, machine)
                badSensorCount = 0
                if Self.systemThermalPressure || temp >= config.emergencyTemp {
                    try forceMaximum(machine); current.phase = "Emergency cooling · maximum speed"
                } else {
                try reassertTurbo(machine)
                }
            }
            current.sensors = machine.sensors.compactMap { sensor in
                guard let v = try? device.read(sensor.key), let c = try? SMCCodec.number(v), SensorDiscovery.valid(c) else { return nil }
                return SensorReading(key: sensor.key, temperature: c, kind: sensor.kind)
            }
            current.fans = FanSnapshotReader().snapshot(device: device, discovery: machine).fans
        } catch {
            badSensorCount += 1
            current.lastError = error.localizedDescription
            if badSensorCount >= 3 { failSafe("sensor or control failure: \(error.localizedDescription)") }
        }
    }

    /// macOS reports `serious` once it is already throttling, and `critical` beyond that. Either
    /// means maximum cooling, including for heat the CPU/GPU die sensors do not capture
    /// (battery, SSD, skin).
    private static var systemThermalPressure: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func tickDaily(_ machine: MachineDiscovery) throws {
        guard var engine = dailyEngine else { dailyEngine = DailyCurveEngine(config: config); return }
        let temperature = (try? controlTemperature(device!, machine))
        let command = engine.tick(temperature: temperature, thermalCritical: Self.systemThermalPressure, fans: try dailyFanSamples(machine))
        dailyEngine = engine
        try executeDailyCommand(command, machine: machine)
    }

    private func dailyFanSamples(_ machine: MachineDiscovery) throws -> [DailyFanSample] {
        try machine.fans.map { fan in
            let range = try fanRange(fan)
            let rpm = (try? Self.number(device!, fan.rpmKey)) ?? range.minimum
            return DailyFanSample(id: fan.index, rpm: rpm, minimum: range.minimum, maximum: range.maximum)
        }
    }

    private func executeDailyCommand(_ command: DailyEngineCommand, machine: MachineDiscovery) throws {
        switch command {
        case .none: break
        case .engage(let targets), .emergency(let targets):
            for target in targets { guard let fan = machine.fans.first(where: { $0.index == target.fanID }) else { continue }; try engage(fan); try setTarget(fan, rpm: target.rpm) }
            current.phase = command.isEmergency ? "Emergency cooling · maximum speed" : "Daily · actively cooling"
        case .update(let targets):
            for target in targets { guard let fan = machine.fans.first(where: { $0.index == target.fanID }) else { continue }; if ((try? Self.number(device!, fan.modeKey)) ?? 0) != 1 { try engage(fan) }; try setTarget(fan, rpm: target.rpm) }
            current.phase = "Daily · actively cooling"
        case .release:
            try restoreAll(); current.mode = .daily; current.phase = "Daily · system controlled"; dailyEngine = DailyCurveEngine(config: config)
        }
    }

    private func reassertTurbo(_ machine: MachineDiscovery) throws {
        for fan in machine.fans {
            if ((try? Self.number(device!, fan.modeKey)) ?? 0) != 1 { try engage(fan) }
            try setTarget(fan, rpm: fanRange(fan).maximum)
        }
    }
    private func forceMaximum(_ machine: MachineDiscovery) throws {
        for fan in machine.fans { try engage(fan); try setTarget(fan, rpm: fanRange(fan).maximum) }
    }
    private func controlTemperature(_ device: AppleSMC, _ machine: MachineDiscovery) throws -> Double {
        let values = machine.sensors.filter { $0.kind != .other }.compactMap { sensor -> Double? in
            guard let v = try? device.read(sensor.key), let t = try? SMCCodec.number(v), SensorDiscovery.valid(t) else { return nil }
            return t
        }
        guard let max = values.max() else { throw NSError(domain: "FanPilot", code: 2, userInfo: [NSLocalizedDescriptionKey: "No valid CPU/GPU temperature sensors are available"]) }
        return max
    }

    private func hasExternalController(_ machine: MachineDiscovery, device: AppleSMC) throws -> Bool {
        let modes = try machine.fans.map { try Self.number(device, $0.modeKey) }
        let ftst = machine.hasFtst ? try Self.number(device, "Ftst") : nil
        return try FanOwnership.hasExternalController(modes: modes, thermalUnlock: ftst)
    }

    private func engage(_ fan: FanDescriptor) throws {
        // Daily can release (clearing the persisted intent) and later re-engage on its own,
        // so intent must be written before every manual engage, not only at mode selection.
        if !persist.dirty { try markDirty() }
        try withFanController { try await $0.engageManual(fan) }
    }
    private func setTarget(_ fan: FanDescriptor, rpm: Double) throws {
        try withFanController { try await $0.setTarget(rpm, for: fan) }
    }
    private func fanRange(_ fan: FanDescriptor) throws -> (minimum: Double, maximum: Double) {
        guard let device, let min = try? Self.number(device, fan.minimumKey), let max = try? Self.number(device, fan.maximumKey), min <= max else { throw SMCError.malformed("fan range") }
        return (min, max)
    }
    private func restoreAll() throws {
        guard let machine, device != nil else { current.mode = .normal; liveness.setManual(false); return }
        guard current.mode != .normal || persist.dirty else { return }
        try withFanController { try await $0.releaseAll(clearFtst: self.persist.weSetFtst) }
        persist.weSetFtst = false
        current.mode = .normal; current.phase = "System controlled"; dailyEngine = nil
        current.sensors = []
        persist.dirty = false; try savePersisted()
        liveness.setManual(false)
        current.fans = FanSnapshotReader().snapshot(device: device!, discovery: machine).fans
        current.lastError = nil
        lastRestoreErrorLogged = nil
    }
    /// Last-resort path whenever control cannot be maintained: hand the fans back to the system and,
    /// if even that fails, leave them at maximum instead of at a stale (possibly low) manual target.
    private func failSafe(_ reason: String) {
        logger.error("Fail-safe: \(reason, privacy: .public)")
        do { try restoreAll() }
        catch {
            recordRestoreFailure(error)
            if let machine { try? forceMaximum(machine) }
        }
    }
    private func recordRestoreFailure(_ error: Error) {
        let message = error.localizedDescription
        current.lastError = message
        guard lastRestoreErrorLogged != message else { return }
        logger.error("System-control restore failed: \(message, privacy: .public)")
        lastRestoreErrorLogged = message
    }
    private func withFanController(_ operation: @escaping @Sendable (FanController) async throws -> Void) throws {
        guard let fanController else { throw SMCError.unavailable }
        let result = ControllerResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { try await operation(fanController); result.store(.success(())) }
            catch { result.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        try result.load()
    }
    private func makeSnapshot() -> HelperState {
        guard let device, let machine else { return current }
        var state = FanSnapshotReader().snapshot(device: device, discovery: machine)
        state.mode = current.mode; state.phase = current.phase; state.lastError = current.lastError; state.helperVersion = "1.0"
        state.sensors = current.mode == .normal ? [] : current.sensors
        return state
    }
    private func readPersisted() -> PersistedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return PersistedState() }
        // A state file that exists but cannot be read means we cannot prove the fans are not ours:
        // treat it as dirty so recovery runs.
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            logger.error("Persisted state unreadable; assuming fans may need recovery")
            return PersistedState(dirty: true, weSetFtst: true)
        }
        return state
    }
    private func markDirty() throws { persist.dirty = true; try savePersisted() }
    private func savePersisted() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(stateURL.deletingLastPathComponent().path, 0o700)
        let data = try JSONEncoder().encode(persist)
        try data.write(to: stateURL, options: .atomic)
        _ = chmod(stateURL.path, 0o600)
    }
    private static func number(_ device: AppleSMC, _ key: String) throws -> Double { try SMCCodec.number(device.read(key)) }
}
