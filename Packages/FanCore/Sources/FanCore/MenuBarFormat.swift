import Foundation

/// The text next to the fan icon in the menu bar. The real menu-bar item and the preview in Settings
/// both call this, so what Settings promises is exactly what the menu bar shows.
public enum MenuBarFormat {
    public static let displayOptions = ["icon", "temperature", "rpm", "both"]

    /// Returns nil when only the icon should be shown (or when there is nothing to show yet).
    public static func text(display: String, celsius: Double?, rpm: Int?, unit: TemperatureUnit) -> String? {
        let temperature = celsius.map { "\(unit.degrees($0))\(unit.symbol)" }
        let speed = rpm.map { "\($0) rpm" }
        switch display {
        case "temperature": return temperature
        case "rpm": return speed
        case "both":
            // A menu-bar label renders a single text item, so both values live in one string.
            return [temperature, speed].compactMap { $0 }.joined(separator: "  ·  ").nilIfEmpty
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
