import Foundation

public enum FanMode: Int, Codable, CaseIterable, Sendable {
    case normal = 0, daily = 1, turbo = 2
    public var title: String { ["Normal", "Daily", "Turbo"][rawValue] }
}

public struct DailyConfig: Codable, Equatable, Sendable {
    public var startTemp: Double = 60
    public var fullTemp: Double = 85
    public var emergencyTemp: Double = 95
    public var releaseHysteresis: Double = 8
    public var engageDelay: Int = 3
    public var releaseDelay: Int = 30
    public var rampDownRate: Double = 0.03

    public init() {}
    public func validated() -> DailyConfig {
        var c = self
        c.startTemp = c.startTemp.isFinite ? min(75, max(45, c.startTemp)) : 60
        c.fullTemp = c.fullTemp.isFinite ? min(95, max(c.startTemp + 10, c.fullTemp)) : max(85, c.startTemp + 10)
        c.emergencyTemp = 95
        c.releaseHysteresis = c.releaseHysteresis.isFinite ? min(15, max(4, c.releaseHysteresis)) : 8
        c.engageDelay = min(10, max(1, c.engageDelay))
        c.releaseDelay = min(120, max(10, c.releaseDelay))
        c.rampDownRate = c.rampDownRate.isFinite ? min(0.10, max(0.01, c.rampDownRate)) : 0.03
        return c
    }
}

public struct FanReading: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var rpm: Double
    public var target: Double
    public var minimum: Double
    public var maximum: Double
    public var manual: Bool
    public init(id: Int, name: String, rpm: Double, target: Double, minimum: Double, maximum: Double, manual: Bool) {
        self.id = id; self.name = name; self.rpm = rpm; self.target = target
        self.minimum = minimum; self.maximum = maximum; self.manual = manual
    }
}

public struct SensorReading: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case cpu = "CPU", gpu = "GPU", other = "Other" }
    public var id: String { key }
    public let key: String
    public let temperature: Double
    public let kind: Kind
    public init(key: String, temperature: Double, kind: Kind) { self.key = key; self.temperature = temperature; self.kind = kind }
}

public struct HelperState: Codable, Equatable, Sendable {
    public var mode: FanMode = .normal
    public var phase: String = "System controlled"
    public var fans: [FanReading] = []
    public var sensors: [SensorReading] = []
    public var controlTemperature: Double? { sensors.filter { $0.kind != .other }.map(\.temperature).max() }
    public var lastError: String?
    public var helperVersion: String = "1.0"
    public init() {}
}

public enum FanCurve {
    public static func target(temperature: Double, minimum: Double, maximum: Double, config raw: DailyConfig) -> Double {
        let config = raw.validated()
        let t = min(1, max(0, (temperature - config.startTemp) / (config.fullTemp - config.startTemp)))
        return min(maximum, max(minimum, minimum + (maximum - minimum) * t))
    }

    public static func nextTarget(curveTarget: Double, previous: Double, minimum: Double, maximum: Double, config raw: DailyConfig) -> Double {
        let maxDrop = (maximum - minimum) * raw.validated().rampDownRate
        return min(maximum, max(minimum, max(curveTarget, previous - maxDrop)))
    }

    public static func filtered(previous: Double, sample: Double) -> Double {
        sample > previous ? 0.6 * sample + 0.4 * previous : 0.15 * sample + 0.85 * previous
    }
}
