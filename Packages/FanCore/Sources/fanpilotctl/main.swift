import Foundation
import FanCore

nonisolated(unsafe) var stopRequested = false

func requireRoot() throws {
    guard geteuid() == 0 else { throw NSError(domain: "fanpilotctl", code: 77, userInfo: [NSLocalizedDescriptionKey: "This command writes SMC keys and must run as root (use sudo)."]) }
}

/// Phase 1 spike: take one fan to a fixed RPM, hold it (thermalmonitord reclaims the fan if the
/// controlling process exits), then always hand control back to macOS.
func testEngage(_ args: [String]) throws {
    try requireRoot()
    guard args.count >= 2, let index = Int(args[0]), let rpm = Double(args[1]), rpm.isFinite, rpm > 0 else {
        throw NSError(domain: "fanpilotctl", code: 64, userInfo: [NSLocalizedDescriptionKey: "Usage: sudo fanpilotctl test-engage <fan index> <rpm> [seconds]"])
    }
    let seconds = args.count > 2 ? max(1, min(300, Int(args[2]) ?? 20)) : 20
    let device = try AppleSMC()
    let machine = try FanDiscovery.inspect(device: device)
    guard let fan = machine.fans.first(where: { $0.index == index }) else { throw NSError(domain: "fanpilotctl", code: 65, userInfo: [NSLocalizedDescriptionKey: "No fan with index \(index)"]) }
    let modes = try machine.fans.map { try SMCCodec.number(device.read($0.modeKey)) }
    let ftst = machine.hasFtst ? try SMCCodec.number(device.read("Ftst")) : nil
    guard try !FanOwnership.hasExternalController(modes: modes, thermalUnlock: ftst) else {
        throw NSError(domain: "fanpilotctl", code: 66, userInfo: [NSLocalizedDescriptionKey: "Fans are already in manual mode; another tool may be controlling them. Nothing was changed."])
    }
    let controller = FanController(device: device, fans: machine.fans, hasFtst: machine.hasFtst)
    for sig in [SIGINT, SIGTERM] { signal(sig) { _ in stopRequested = true } }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    Task {
        do {
            defer { done.signal() }
            do {
                print("Engaging \(fan.name) (\(fan.modeKey))…")
                try await controller.engageManual(fan)
                var elapsed = 0
                while elapsed < seconds, !stopRequested {
                    try await controller.setTarget(rpm, for: fan)
                    let live = (try? SMCCodec.number(device.read(fan.rpmKey))).map { String(format: "%.0f", $0) } ?? "?"
                    print("  t=\(elapsed)s target \(Int(rpm)) RPM, actual \(live) RPM")
                    try await Task.sleep(for: .seconds(2)); elapsed += 2
                }
            } catch { failure = error }
            try await controller.releaseAll(clearFtst: true)
            print("Released: fans are back under macOS control.")
        } catch { failure = failure ?? error }
    }
    done.wait()
    if let failure { throw failure }
}

/// Force every fan back to system control and clear Ftst. Safe to run at any time.
func restore() throws {
    try requireRoot()
    let device = try AppleSMC()
    let machine = try FanDiscovery.inspect(device: device)
    let controller = FanController(device: device, fans: machine.fans, hasFtst: machine.hasFtst)
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    Task {
        do { try await controller.releaseAll(clearFtst: true); print("System fan control restored.") }
        catch { failure = error }
        done.signal()
    }
    done.wait()
    if let failure { throw failure }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "test-engage": try testEngage(Array(arguments.dropFirst())); return
    case "restore": try restore(); return
    case "dump": break
    default:
        print("Usage: fanpilotctl dump [--json] | sudo fanpilotctl test-engage <fan> <rpm> [seconds] | sudo fanpilotctl restore")
        throw NSError(domain: "fanpilotctl", code: 64)
    }
    guard SMCLayout.validate() else { throw SMCError.malformed("SMCParamStruct memory layout") }
    let device = try AppleSMC()
    let machine = try FanDiscovery.inspect(device: device)
    let system = Process()
    system.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    system.arguments = ["-n", "hw.model"]
    let modelPipe = Pipe(); system.standardOutput = modelPipe; system.standardError = FileHandle.nullDevice
    try? system.run(); let modelData = modelPipe.fileHandleForReading.readDataToEndOfFile(); system.waitUntilExit()
    let model = ProcessInfo.processInfo.environment["MODEL_IDENTIFIER"] ?? String(decoding: modelData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let fanRows: [[String: Any]] = machine.fans.map { fan in
        let rpm = (try? SMCCodec.number(device.read(fan.rpmKey)))
        let target = (try? SMCCodec.number(device.read(fan.targetKey)))
        let minimum = (try? SMCCodec.number(device.read(fan.minimumKey)))
        let maximum = (try? SMCCodec.number(device.read(fan.maximumKey)))
        let mode = (try? SMCCodec.number(device.read(fan.modeKey)))
        let modeInfo = try? device.keyInfo(fan.modeKey)
        return ["index": fan.index, "name": fan.name, "modeKey": fan.modeKey, "modeType": modeInfo?.type ?? "unknown", "modeSize": modeInfo?.size ?? 0, "modeAttributes": modeInfo?.attributes ?? 0, "mode": mode as Any? ?? NSNull(), "rpm": rpm as Any? ?? NSNull(), "target": target as Any? ?? NSNull(), "minimum": minimum as Any? ?? NSNull(), "maximum": maximum as Any? ?? NSNull()]
    }
    let ftst = try? SMCCodec.number(device.read("Ftst"))
    if CommandLine.arguments.contains("--json") {
        let result: [String: Any] = [
            "model": model,
            "fanless": machine.fanless,
            "hasFtst": machine.hasFtst,
            "ftst": ftst as Any? ?? NSNull(),
            "fans": fanRows,
            "sensors": machine.sensors.map { ["key": $0.key, "temperature": $0.temperature, "kind": $0.kind.rawValue] }
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("FanPilot hardware diagnostics — \(model)")
        print("SMC layout: valid (\(MemoryLayout<SMCParamStruct>.stride) bytes)")
        print("Fans: \(machine.fans.count), Ftst: \(machine.hasFtst ? "present (\(ftst.map(String.init(describing:)) ?? "unreadable"))" : "absent")")
        if machine.fans.isEmpty { print("No controllable fans detected (monitor-only)") }
        for fan in machine.fans {
            let rpm = (try? SMCCodec.number(device.read(fan.rpmKey))).map { String(format: "%.0f RPM", $0) } ?? "unknown RPM"
            let target = (try? SMCCodec.number(device.read(fan.targetKey))).map { String(format: "target %.0f", $0) } ?? "unknown target"
            let min = (try? SMCCodec.number(device.read(fan.minimumKey))).map { String(format: "min %.0f", $0) } ?? "unknown min"
            let max = (try? SMCCodec.number(device.read(fan.maximumKey))).map { String(format: "max %.0f", $0) } ?? "unknown max"
            let mode = (try? SMCCodec.number(device.read(fan.modeKey))).map { String(format: "mode %.0f", $0) } ?? "unknown mode"
            let info = try? device.keyInfo(fan.modeKey)
            print("  \(fan.name): \(rpm), \(target), \(min)…\(max), \(mode), mode key \(fan.modeKey) [\(info?.type ?? "unknown") / \(info?.size ?? 0) bytes]")
        }
        print("Valid temperature sensors: \(machine.sensors.count)")
        for sensor in machine.sensors.sorted(by: { $0.temperature > $1.temperature }) { print(String(format: "  %@  %.1f°C  %@", sensor.key, sensor.temperature, sensor.kind.rawValue)) }
        if let t = machine.controlTemperature { print(String(format: "Control temperature: %.1f°C", t)) }
    }
}

do { try main() } catch { fputs("fanpilotctl: \(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
