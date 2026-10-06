import XCTest
@testable import FanCore

final class FanCoreTests: XCTestCase {
    func testSMCLayout() { XCTAssertTrue(SMCLayout.validate()) }

    func testFanSnapshotUsesCachedFanRanges() throws {
        let smc = FakeSMC()
        let machine = try FanDiscovery.inspect(device: smc)
        let state = FanSnapshotReader().snapshot(device: smc, discovery: machine, cachedRanges: [
            0: (minimum: 1500, maximum: 7000), 1: (minimum: 1600, maximum: 7100)
        ])
        XCTAssertEqual(state.fans.map(\.minimum), [1500, 1600])
        XCTAssertEqual(state.fans.map(\.maximum), [7000, 7100])
    }

    func testCodecRoundTrips() throws {
        for (type, size, value) in [("flt ", 4, 42.25), ("sp78", 2, -12.5), ("fpe2", 2, 6400.0), ("ui8 ", 1, 42.0), ("ui16", 2, 4200.0), ("ui32", 4, 4_200_000.0)] {
            let raw = try SMCCodec.bytes(value, type: type, size: size)
            let decoded = try SMCCodec.number(SMCValue(info: SMCKeyInfo(size: size, type: type, attributes: 0), bytes: raw))
            XCTAssertEqual(decoded, value, accuracy: 0.01, "\(type)")
        }
    }

    func testSMCErrorMappingAndCodecRejectsMalformedValues() throws {
        if case .badCommand = SMCError.result(0x82) {} else { XCTFail("0x82 should map to badCommand") }
        if case .notFound = SMCError.result(0x84) {} else { XCTFail("0x84 should map to notFound") }
        if case .notWritable = SMCError.result(0x86) {} else { XCTFail("0x86 should map to notWritable") }
        if case .sizeMismatch = SMCError.result(0x87) {} else { XCTFail("0x87 should map to sizeMismatch") }
        XCTAssertThrowsError(try SMCCodec.bytes(255.6, type: "ui8 ", size: 1))
        XCTAssertThrowsError(try SMCCodec.bytes(16_383.9, type: "fpe2", size: 2))
        XCTAssertThrowsError(try SMCCodec.number(SMCValue(info: SMCKeyInfo(size: 4, type: "flt ", attributes: 0), bytes: [0])))
    }

    func testConfigValidationAndCurve() {
        var config = DailyConfig(); config.startTemp = 200; config.fullTemp = 10; config.engageDelay = 0
        let safe = config.validated()
        XCTAssertEqual(safe.startTemp, 75); XCTAssertEqual(safe.fullTemp, 85); XCTAssertEqual(safe.engageDelay, 1)
        XCTAssertEqual(FanCurve.target(temperature: 60, minimum: 1200, maximum: 6000, config: DailyConfig()), 1200)
        XCTAssertEqual(FanCurve.target(temperature: 85, minimum: 1200, maximum: 6000, config: DailyConfig()), 6000)
    }

    func testRampDownIsLimitedButRiseIsImmediate() {
        var c = DailyConfig(); c.rampDownRate = 0.03
        XCTAssertEqual(FanCurve.nextTarget(curveTarget: 1000, previous: 4000, minimum: 1000, maximum: 5000, config: c), 3880)
        XCTAssertEqual(FanCurve.nextTarget(curveTarget: 4500, previous: 2000, minimum: 1000, maximum: 5000, config: c), 4500)
    }

    func testSensorValidityAndFanWriteAllowList() {
        XCTAssertFalse(SensorDiscovery.valid(0)); XCTAssertTrue(SensorDiscovery.valid(5)); XCTAssertTrue(SensorDiscovery.valid(130)); XCTAssertFalse(SensorDiscovery.valid(131))
        XCTAssertTrue(FanWritePolicy.permits("F0Tg", fanCount: 2)); XCTAssertTrue(FanWritePolicy.permits("F1md", fanCount: 2))
        XCTAssertFalse(FanWritePolicy.permits("F0Mx", fanCount: 2)); XCTAssertFalse(FanWritePolicy.permits("F9Tg", fanCount: 2)); XCTAssertTrue(FanWritePolicy.permits("Ftst", fanCount: 0))
    }

    func testFanOwnershipAcceptsKnownSystemModesAndRejectsUnknownValues() throws {
        XCTAssertFalse(try FanOwnership.hasExternalController(modes: [0, 3], thermalUnlock: 0))
        XCTAssertTrue(try FanOwnership.hasExternalController(modes: [0, 1], thermalUnlock: 0))
        XCTAssertTrue(try FanOwnership.hasExternalController(modes: [0, 0], thermalUnlock: 1))
        XCTAssertThrowsError(try FanOwnership.hasExternalController(modes: [2], thermalUnlock: 0))
        XCTAssertThrowsError(try FanOwnership.hasExternalController(modes: [0], thermalUnlock: 2))
    }

    func testFakeSMCDiscoveryAndUnlockRetry() async throws {
        let smc = FakeSMC()
        let found = try FanDiscovery.inspect(device: smc)
        XCTAssertEqual(found.fans.map(\.modeKey), ["F0Md", "F1Md"])
        XCTAssertEqual(found.controlTemperature, 45)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 3)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: found.hasFtst, retryInterval: 0.001, retryCount: 5)
        try await controller.engageManual(found.fans[0])
        try await controller.setTarget(-400, for: found.fans[0])
        XCTAssertEqual(try smc.value("F0Tg"), 1200)
        try await controller.setTarget(9000, for: found.fans[0])
        XCTAssertEqual(try smc.value("F0Tg"), 6000)
        XCTAssertEqual(try smc.value("Ftst"), 1)
        XCTAssertEqual(try smc.value("F0Md"), 1)
        let owns = await controller.ownsThermalUnlock()
        XCTAssertTrue(owns)
    }

    func testEngageRetriesUntilManualModeIsActuallyAcknowledged() async throws {
        let smc = FakeSMC(fans: 1)
        let found = try FanDiscovery.inspect(device: smc)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 1)
        smc.delayManualAcknowledgements(2)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: true, retryInterval: 0, retryCount: 4)
        try await controller.engageManual(found.fans[0])
        XCTAssertEqual(try smc.value("F0Md"), 1)
        XCTAssertEqual(try smc.value("Ftst"), 1)
    }

    func testUnlockIsReleasedOnlyAfterLastFan() async throws {
        let smc = FakeSMC()
        let found = try FanDiscovery.inspect(device: smc)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 1)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: true, retryInterval: 0, retryCount: 2)
        try await controller.engageManual(found.fans[0])
        try await controller.engageManual(found.fans[1])
        try await controller.release(found.fans[0])
        XCTAssertEqual(try smc.value("Ftst"), 1)
        try await controller.release(found.fans[1])
        XCTAssertEqual(try smc.value("Ftst"), 0)
        let owns = await controller.ownsThermalUnlock()
        XCTAssertFalse(owns)
    }

    func testReleaseAllLeavesKnownFirmwareAutomaticModeUntouched() async throws {
        let smc = FakeSMC(fans: 1, hasFtst: false)
        let found = try FanDiscovery.inspect(device: smc)
        try smc.write("F0Md", bytes: SMCCodec.bytes(3, type: "ui8 ", size: 1))
        let controller = FanController(device: smc, fans: found.fans, hasFtst: false)
        try await controller.releaseAll()
        XCTAssertEqual(try smc.value("F0Md"), 3)
    }

    func testReleaseAcceptsM4FirmwareAutomaticModeValue() async throws {
        let smc = FakeSMC(fans: 1)
        smc.setAutomaticModeValue(3)
        let found = try FanDiscovery.inspect(device: smc)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 1)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: true, retryInterval: 0, retryCount: 2)
        try await controller.engageManual(found.fans[0])
        XCTAssertEqual(try smc.value("F0Md"), 1)
        try await controller.release(found.fans[0])
        XCTAssertEqual(try smc.value("F0Md"), 3)
        XCTAssertEqual(try smc.value("Ftst"), 0)
    }

    func testReleaseWaitsForFirmwareAutomaticModeReadback() async throws {
        let smc = FakeSMC(fans: 1)
        smc.setAutomaticModeValue(3)
        let found = try FanDiscovery.inspect(device: smc)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 1)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: true, retryInterval: 0, retryCount: 4)
        try await controller.engageManual(found.fans[0])
        try await controller.release(found.fans[0])
        XCTAssertEqual(try smc.value("F0Md"), 3)
        XCTAssertEqual(try smc.value("Ftst"), 0)
    }

    func testTargetWaitsForHardwareReadback() async throws {
        let smc = FakeSMC(fans: 1)
        let found = try FanDiscovery.inspect(device: smc)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: true, retryInterval: 0, retryCount: 4)
        smc.delayTargetAcknowledgements(2)
        try await controller.setTarget(5000, for: found.fans[0])
        XCTAssertEqual(try smc.value("F0Tg"), 5000)
    }

    func testFakeSMCUsesLowercaseModeKeyVariant() throws {
        let smc = FakeSMC(modeKeyLowercase: true)
        let found = try FanDiscovery.inspect(device: smc)
        XCTAssertEqual(found.fans.map(\.modeKey), ["F0md", "F1md"])
    }

    func testManualModeRefusalWithoutFtstIsSurfaced() async throws {
        let smc = FakeSMC(hasFtst: false)
        let found = try FanDiscovery.inspect(device: smc)
        smc.failNextWrites(to: "F0Md", code: 0x82, count: 1)
        let controller = FanController(device: smc, fans: found.fans, hasFtst: false, retryInterval: 0, retryCount: 1)
        do { try await controller.engageManual(found.fans[0]); XCTFail("Expected firmware refusal") }
        catch SMCError.badCommand { }
    }

    func testDailyEngineEngagesBumplesslyAndReleasesAfterHysteresis() {
        var config = DailyConfig(); config.startTemp = 60; config.engageDelay = 2; config.releaseDelay = 2
        let fans = [DailyFanSample(id: 0, rpm: 2400, minimum: 1200, maximum: 6000)]
        var engine = DailyCurveEngine(config: config)
        XCTAssertEqual(engine.tick(temperature: 63, fans: fans), .none)
        guard case .engage(let engaged) = engine.tick(temperature: 64, fans: fans) else { return XCTFail("Expected engage after sustained heat") }
        XCTAssertGreaterThanOrEqual(engaged[0].rpm, fans[0].rpm, "Engage must not step down below current fan speed")
        guard case .update(let firstCoolTarget) = engine.tick(temperature: 48, fans: fans) else { return XCTFail("Expected a controlled ramp down") }
        XCTAssertEqual(engaged[0].rpm - firstCoolTarget[0].rpm, 144, accuracy: 0.001)
        var released = false
        for _ in 0..<80 where !released {
            released = engine.tick(temperature: 40, fans: fans) == .release
        }
        XCTAssertTrue(released, "Sustained cool readings should eventually release control")
    }

    func testDailyEngineLimitsRampDownAndForcesEmergencyMaximum() {
        var config = DailyConfig(); config.startTemp = 50; config.engageDelay = 1; config.releaseDelay = 120
        let fans = [DailyFanSample(id: 0, rpm: 2000, minimum: 1000, maximum: 5000)]
        var engine = DailyCurveEngine(config: config)
        guard case .engage = engine.tick(temperature: 70, fans: fans) else { return XCTFail("Expected engage") }
        guard case .update(let lowered) = engine.tick(temperature: 49, fans: fans) else { return XCTFail("Expected target update") }
        XCTAssertEqual(lowered[0].rpm, 3165, accuracy: 1)
        XCTAssertEqual(engine.tick(temperature: 95, fans: fans), .emergency([DailyTarget(fanID: 0, rpm: 5000)]))
    }

    func testDailyEngineReleasesAfterThreeInvalidSamples() {
        var config = DailyConfig(); config.startTemp = 50; config.engageDelay = 1
        let fans = [DailyFanSample(id: 0, rpm: 2000, minimum: 1000, maximum: 5000)]
        var engine = DailyCurveEngine(config: config)
        guard case .engage = engine.tick(temperature: 70, fans: fans) else { return XCTFail("Expected engage") }
        XCTAssertEqual(engine.tick(temperature: nil, fans: fans), .none)
        XCTAssertEqual(engine.tick(temperature: 0, fans: fans), .none)
        XCTAssertEqual(engine.tick(temperature: nil, fans: fans), .release)
        XCTAssertEqual(engine.phase, .system)
    }

    func testDailyEngineHonorsCriticalThermalStateWithoutTemperature() {
        var engine = DailyCurveEngine()
        let fans = [DailyFanSample(id: 0, rpm: 1000, minimum: 1000, maximum: 5000)]
        XCTAssertEqual(engine.tick(temperature: nil, thermalCritical: true, fans: fans), .emergency([DailyTarget(fanID: 0, rpm: 5000)]))
    }

    func testDailyEngineHoldsMaximumUnderSustainedNinetyDegrees() {
        let fans = [DailyFanSample(id: 0, rpm: 1500, minimum: 1200, maximum: 6000), DailyFanSample(id: 1, rpm: 1500, minimum: 1200, maximum: 6000)]
        var engine = DailyCurveEngine()
        var commands: [DailyEngineCommand] = []
        for _ in 0..<300 { commands.append(engine.tick(temperature: 90, fans: fans)) }
        XCTAssertEqual(commands[0], .none)
        guard case .engage(let first) = commands[2] else { return XCTFail("Expected engage after the 3 s engage delay") }
        XCTAssertEqual(first.map(\.rpm), [6000, 6000])
        for command in commands.dropFirst(3) {
            guard case .update(let targets) = command else { return XCTFail("Sustained heat must never release or go idle") }
            XCTAssertEqual(targets.map(\.rpm), [6000, 6000])
        }
        XCTAssertEqual(engine.phase, .manual)
    }

    func testDailyEngineIgnoresBriefSpikeThatDropsBackBelowStart() {
        let fans = [DailyFanSample(id: 0, rpm: 0, minimum: 1200, maximum: 6000)]
        var engine = DailyCurveEngine()
        XCTAssertEqual(engine.tick(temperature: 62, fans: fans), .none)
        for _ in 0..<60 { XCTAssertEqual(engine.tick(temperature: 45, fans: fans), .none) }
        XCTAssertEqual(engine.phase, .system, "A one-second blip must not take control from macOS")
    }

    func testDiscoveryKeepsSensorsThatAreInvalidWhileTheirCoresAreOff() throws {
        let smc = FakeSMC()
        smc.seed("Tp0A", number: 0, type: "flt ", size: 4)     // powered-off cluster at startup
        smc.seed("Tg0B", number: 200, type: "flt ", size: 4)   // out of range at startup
        smc.seed("TC0P", number: 40, type: "sp78", size: 2)
        smc.seed("Tx", number: 1, type: "ui8 ", size: 1)       // not a temperature encoding
        let found = try FanDiscovery.inspect(device: smc)
        let keys = Set(found.sensors.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: ["Tp01", "Tp0A", "Tg0B", "TC0P"]), "Sensors must not be dropped for a transient invalid reading")
        XCTAssertFalse(keys.contains("Tx"))
        XCTAssertEqual(found.sensors.first { $0.key == "Tp0A" }?.kind, .cpu)
        XCTAssertEqual(found.controlTemperature, 45, "Placeholder readings must not influence the discovery temperature")
        smc.seed("Tp0A", number: 88, type: "flt ", size: 4)    // the cluster wakes under load
        let live = try SMCCodec.number(smc.read("Tp0A"))
        XCTAssertTrue(SensorDiscovery.valid(live))
    }

    func testTemperatureUnitConversions() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(0), 32, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(100), 212, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.celsius.convert(61.4), 61.4, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convertDifference(5), 9, accuracy: 1e-9, "A difference has no +32 offset")
        for celsius in [-10.0, 0, 37.5, 60, 85, 95] {
            let shown = TemperatureUnit.fahrenheit.convert(celsius)
            XCTAssertEqual(TemperatureUnit.fahrenheit.toCelsius(shown), celsius, accuracy: 1e-9)
            XCTAssertEqual(TemperatureUnit.fahrenheit.toCelsiusDifference(TemperatureUnit.fahrenheit.convertDifference(celsius)), celsius, accuracy: 1e-9)
        }
        XCTAssertEqual(TemperatureUnit.fahrenheit.degrees(71), 160)   // 159.8 rounds to 160
        XCTAssertEqual(TemperatureUnit.celsius.degrees(71.4), 71)
        XCTAssertEqual(TemperatureUnit.fahrenheit.symbol, "°F")
        XCTAssertEqual(TemperatureUnit(rawValue: "celsius"), .celsius)
    }

    func testMenuBarTextMatchesEachSettingsOption() {
        let c = TemperatureUnit.celsius, f = TemperatureUnit.fahrenheit
        XCTAssertNil(MenuBarFormat.text(display: "icon", celsius: 65, rpm: 2300, unit: c))
        XCTAssertEqual(MenuBarFormat.text(display: "temperature", celsius: 65, rpm: 2300, unit: c), "65°C")
        XCTAssertEqual(MenuBarFormat.text(display: "temperature", celsius: 65, rpm: 2300, unit: f), "149°F")
        XCTAssertEqual(MenuBarFormat.text(display: "rpm", celsius: 65, rpm: 2300, unit: c), "2300 rpm")
        XCTAssertEqual(MenuBarFormat.text(display: "rpm", celsius: 65, rpm: 0, unit: c), "0 rpm")
        XCTAssertEqual(MenuBarFormat.text(display: "both", celsius: 65, rpm: 2300, unit: c), "65°C  ·  2300 rpm")
        XCTAssertEqual(MenuBarFormat.text(display: "both", celsius: nil, rpm: 2300, unit: c), "2300 rpm", "A missing value must not leave a dangling separator")
        XCTAssertNil(MenuBarFormat.text(display: "both", celsius: nil, rpm: nil, unit: c))
        XCTAssertNil(MenuBarFormat.text(display: "unknown", celsius: 65, rpm: 1, unit: c))
    }
}
