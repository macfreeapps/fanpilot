import Foundation

/// How temperatures are shown. Everything inside FanPilot (sensors, thresholds, control) stays in
/// Celsius; this only changes what people read.
public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit

    public var id: String { rawValue }
    public var title: String { self == .celsius ? "Celsius" : "Fahrenheit" }
    public var symbol: String { self == .celsius ? "°C" : "°F" }

    /// The unit people in this region expect: Fahrenheit in the US, Celsius elsewhere.
    public static var regionDefault: TemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }
    public static let storageKey = "temperatureUnit"

    public func convert(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
    /// For differences ("5 degrees cooler"), where the +32 offset does not apply.
    public func convertDifference(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 }
    public func toCelsius(_ shown: Double) -> Double { self == .celsius ? shown : (shown - 32) * 5 / 9 }
    public func toCelsiusDifference(_ shown: Double) -> Double { self == .celsius ? shown : shown * 5 / 9 }

    /// Whole degrees as shown on screen.
    public func degrees(_ celsius: Double) -> Int { Int(convert(celsius).rounded()) }
}
