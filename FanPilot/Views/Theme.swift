import SwiftUI
import FanCore

// MARK: - Friendly names, colours and symbols for the three modes

extension FanMode {
    var tagline: String {
        switch self {
        case .normal: "Your Mac decides"
        case .daily: "Quiet and smart"
        case .turbo: "Maximum cooling"
        }
    }
    var symbol: String {
        switch self {
        case .normal: "leaf.fill"
        case .daily: "wand.and.stars"
        case .turbo: "bolt.fill"
        }
    }
    var tint: Color {
        switch self {
        case .normal: Color(hue: 0.47, saturation: 0.55, brightness: 0.80)   // calm teal
        case .daily: Color(hue: 0.60, saturation: 0.70, brightness: 0.95)    // friendly blue
        case .turbo: Color(hue: 0.07, saturation: 0.85, brightness: 1.00)    // warm orange
        }
    }
}

// MARK: - Temperature language and colour

enum Thermal {
    /// 30°C and below is an empty gauge, 100°C is full.
    static func fraction(_ celsius: Double) -> Double { min(1, max(0, (celsius - 30) / 70)) }

    private static let hueStops: [(Double, Double)] = [(35, 0.52), (55, 0.40), (72, 0.14), (85, 0.07), (97, 0.0)]

    private static func hue(_ celsius: Double) -> Double {
        guard let first = hueStops.first, let last = hueStops.last else { return 0.4 }
        if celsius <= first.0 { return first.1 }
        if celsius >= last.0 { return last.1 }
        for (low, high) in zip(hueStops, hueStops.dropFirst()) where celsius <= high.0 {
            return low.1 + (high.1 - low.1) * (celsius - low.0) / (high.0 - low.0)
        }
        return last.1
    }

    /// Blue-green when cool, through yellow and orange, to red when very hot. For shapes and fills.
    static func color(_ celsius: Double) -> Color {
        Color(hue: hue(celsius), saturation: celsius >= 97 ? 0.80 : 0.70, brightness: 0.97)
    }

    /// The same hue for text: bright on dark backgrounds, darkened on light ones so it stays readable.
    static func textColor(_ celsius: Double) -> Color {
        let hue = hue(celsius)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(hue: hue, saturation: 0.65, brightness: 0.97, alpha: 1)
                        : NSColor(hue: hue, saturation: 0.95, brightness: 0.52, alpha: 1)
        })
    }

    static func word(_ celsius: Double) -> String {
        switch celsius {
        case ..<50: "Cool"
        case ..<68: "Comfortable"
        case ..<80: "Warm"
        case ..<90: "Hot"
        default: "Very hot"
        }
    }
}

// MARK: - One plain-language summary of "what is my Mac doing right now"

struct CoolingSummary {
    var headline: String
    var detail: String
    var temperature: Double?
    var fans: [FanReading]
    var averageSpeed: Double          // 0...1 of the fans' maximum
    var isResting: Bool
    var tint: Color

    @MainActor
    init(monitor: Monitor, helper: HelperClient) {
        let helperFans = helper.installed && !helper.snapshot.fans.isEmpty ? helper.snapshot.fans : monitor.state.fans
        fans = helperFans
        temperature = monitor.displayTemperature
        let fractions = helperFans.map { $0.maximum > 0 ? min(1, max(0, $0.rpm / $0.maximum)) : 0 }
        averageSpeed = fractions.isEmpty ? 0 : fractions.reduce(0, +) / Double(fractions.count)
        isResting = helperFans.allSatisfy { $0.rpm < 50 }
        let percent = Int((averageSpeed * 20).rounded()) * 5      // 5% steps: see FanRow
        let mode = helper.mode
        // Only claim "cool" when the temperature agrees.
        let restingHeadline = (monitor.displayTemperature ?? 0) < 68 ? "Cool and quiet" : "Fans are resting"
        tint = (helper.installed ? mode : .normal).tint

        if !monitor.connected {
            headline = "Checking your Mac…"; detail = "Reading fans and temperatures."
        } else if helperFans.isEmpty {
            headline = "No fans to control"; detail = "This Mac cools itself without fans. FanPilot will still show its temperature."
        } else if helper.installed && helper.changingMode && mode != .normal {
            headline = "Getting ready…"; detail = "Taking over the fans. This can take a few seconds."
        } else if !helper.installed {
            headline = isResting ? restingHeadline : "Your Mac is cooling itself"
            detail = isResting ? "macOS is handling the cooling. Turn on fan control below to choose how your Mac cools." : "Fans at \(percent)%. Turn on fan control below to choose how your Mac cools."
        } else {
            switch mode {
            case .normal:
                headline = isResting ? restingHeadline : "Your Mac is cooling itself"
                detail = isResting ? (restingHeadline == "Fans are resting" ? "macOS is handling the cooling on its own." : "The fans are resting. macOS is in charge.") : "Fans at \(percent)%. macOS is in charge."
            case .daily:
                let working = helper.snapshot.fans.contains { $0.manual }
                headline = working ? "Keeping your Mac cool" : "Smart cooling is on"
                detail = working ? "Fans at \(percent)%, adjusting to the temperature." : "Fans rest until your Mac needs them."
            case .turbo:
                headline = "Maximum cooling"
                detail = "Fans at \(percent)%. It will be a little louder."
            }
        }
    }
}

// MARK: - The menu-bar icon (shared by the real menu bar and the preview in Settings)

enum MenuBarIcon {
    /// Normal (or no fan control yet) draws a plain template icon that follows the menu bar's light or
    /// dark look. Daily and Turbo draw a coloured icon so the mode is visible at a glance.
    @MainActor static func image(mode: FanMode, controlling: Bool) -> NSImage {
        let symbol = controlling && mode == .turbo ? "fanblades.fill" : "fanblades"
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "FanPilot") ?? NSImage()
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard controlling, mode != .normal else {
            let image = base.withSymbolConfiguration(size) ?? base
            image.isTemplate = true
            return image
        }
        let coloured = size.applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(mode.tint)]))
        let image = base.withSymbolConfiguration(coloured) ?? base
        image.isTemplate = false
        return image
    }
}

// MARK: - Shared look and feel

/// A soft press effect for every button.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension Animation {
    static let friendly = Animation.spring(response: 0.5, dampingFraction: 0.78)
}

extension View {
    /// The rounded "card" surface used across the app.
    func cardBackground(cornerRadius: CGFloat = 18) -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

/// Opens Settings from anywhere, including the menu-bar panel. `SettingsLink` alone does nothing there:
/// the app is not active and an already-open Settings window is not brought forward.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            raiseSettingsWindow()
            // A window that is being created appears a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { raiseSettingsWindow() }
        } label: { label }
    }

    private func raiseSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
