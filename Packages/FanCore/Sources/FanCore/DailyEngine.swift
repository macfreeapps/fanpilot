import Foundation

public struct DailyFanSample: Sendable {
    public let id: Int
    public let rpm: Double
    public let minimum: Double
    public let maximum: Double
    public init(id: Int, rpm: Double, minimum: Double, maximum: Double) {
        self.id = id; self.rpm = rpm; self.minimum = minimum; self.maximum = maximum
    }
}

public struct DailyTarget: Sendable, Equatable {
    public let fanID: Int
    public let rpm: Double
    public init(fanID: Int, rpm: Double) { self.fanID = fanID; self.rpm = rpm }
}

public enum DailyEnginePhase: Sendable, Equatable { case system, manual }
public enum DailyEngineCommand: Sendable, Equatable {
    case none
    case engage([DailyTarget])
    case update([DailyTarget])
    case emergency([DailyTarget])
    case release

    public var isEmergency: Bool { if case .emergency = self { return true }; return false }
}

public struct DailyCurveEngine: Sendable {
    public private(set) var phase: DailyEnginePhase = .system
    public private(set) var filteredTemperature: Double?
    public let config: DailyConfig
    private var secondsAboveStart = 0
    private var secondsBelowRelease = 0
    private var invalidSamples = 0
    private var previousTargets: [Int: Double] = [:]

    public init(config: DailyConfig = DailyConfig()) { self.config = config.validated() }

    public mutating func adoptManualControl(temperature: Double, fans: [DailyFanSample]) {
        phase = .manual
        filteredTemperature = temperature
        previousTargets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, max($0.minimum, $0.rpm)) })
        secondsAboveStart = 0; secondsBelowRelease = 0; invalidSamples = 0
    }

    public mutating func tick(temperature raw: Double?, thermalCritical: Bool = false, fans: [DailyFanSample]) -> DailyEngineCommand {
        guard !fans.isEmpty else {
            invalidSamples += 1
            guard invalidSamples >= 3 else { return .none }
            resetToSystem()
            return .release
        }
        if thermalCritical {
            invalidSamples = 0
            phase = .manual; secondsAboveStart = 0; secondsBelowRelease = 0
            let targets = fans.map { DailyTarget(fanID: $0.id, rpm: $0.maximum) }
            previousTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.fanID, $0.rpm) })
            return .emergency(targets)
        }
        guard let raw, SensorDiscovery.valid(raw) else {
            invalidSamples += 1
            guard invalidSamples >= 3 else { return .none }
            resetToSystem()
            return .release
        }
        invalidSamples = 0
        filteredTemperature = filteredTemperature.map { FanCurve.filtered(previous: $0, sample: raw) } ?? raw
        let filtered = filteredTemperature!

        if raw >= config.emergencyTemp {
            phase = .manual; secondsAboveStart = 0; secondsBelowRelease = 0
            let targets = fans.map { DailyTarget(fanID: $0.id, rpm: $0.maximum) }
            previousTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.fanID, $0.rpm) })
            return .emergency(targets)
        }

        switch phase {
        case .system:
            secondsAboveStart = filtered >= config.startTemp ? secondsAboveStart + 1 : 0
            guard secondsAboveStart >= config.engageDelay else { return .none }
            phase = .manual; secondsBelowRelease = 0
            let targets = fans.map { fan in
                let curve = FanCurve.target(temperature: filtered, minimum: fan.minimum, maximum: fan.maximum, config: config)
                return DailyTarget(fanID: fan.id, rpm: max(curve, fan.rpm))
            }
            previousTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.fanID, $0.rpm) })
            return .engage(targets)

        case .manual:
            secondsBelowRelease = filtered <= config.startTemp - config.releaseHysteresis ? secondsBelowRelease + 1 : 0
            if secondsBelowRelease >= config.releaseDelay {
                resetToSystem()
                return .release
            }
            let targets = fans.map { fan in
                let curve = FanCurve.target(temperature: filtered, minimum: fan.minimum, maximum: fan.maximum, config: config)
                let target = FanCurve.nextTarget(curveTarget: curve, previous: previousTargets[fan.id] ?? curve, minimum: fan.minimum, maximum: fan.maximum, config: config)
                return DailyTarget(fanID: fan.id, rpm: target)
            }
            previousTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.fanID, $0.rpm) })
            return .update(targets)
        }
    }

    private mutating func resetToSystem() {
        phase = .system; filteredTemperature = nil; previousTargets.removeAll()
        secondsAboveStart = 0; secondsBelowRelease = 0; invalidSamples = 0
    }
}
