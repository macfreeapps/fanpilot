import SwiftUI
import FanCore

// MARK: - Mode cards

struct ModePicker: View {
    @Bindable var helper: HelperClient
    var config: DailyConfig
    var compact = false
    @Namespace private var selection

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(FanMode.allCases, id: \.self) { mode in card(for: mode) }
        }
        .animation(.friendly, value: helper.mode)
        .opacity(helper.installed ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.3), value: helper.installed)
    }

    private func card(for mode: FanMode) -> some View {
        let selected = helper.installed && helper.mode == mode
        let busy = selected && helper.changingMode && mode != .normal
        return Button { helper.choose(mode, config: config) } label: {
            VStack(spacing: compact ? 3 : 8) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: mode.symbol)
                            .font(.system(size: compact ? 16 : 24, weight: .semibold))
                            .foregroundStyle(selected ? mode.tint : .secondary)
                            .symbolEffect(.bounce, value: selected)
                    }
                }
                .frame(height: compact ? 20 : 30)
                Text(mode.title).font(compact ? .subheadline.weight(.semibold) : .headline)
                if !compact {
                    Text(mode.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 8 : 14)
            .padding(.horizontal, 4)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary)
                    if selected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(mode.tint.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(mode.tint.opacity(0.75), lineWidth: 1.5))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!helper.installed)
        .accessibilityLabel("\(mode.title). \(mode.tagline)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Messages in plain language

enum Friendly {
    /// The warning to show, if any. After the helper restarts it can keep saying another fan app is in
    /// control until the next request re-checks; if no fan is actually under manual control, that message
    /// is stale and is not shown.
    static func issue(helperError: String?, snapshotError: String?, monitorError: String?, anyFanManual: Bool) -> String? {
        guard let raw = helperError ?? snapshotError ?? monitorError else { return nil }
        if raw.contains("Another fan utility"), !anyFanManual { return nil }
        return message(for: raw)
    }

    static func message(for raw: String) -> String {
        if raw.contains("Another fan utility") { return "Another fan app seems to be in control right now. Quit it, then pick a mode again." }
        if raw.contains("does not recognize the current fan state") { return "FanPilot doesn't recognize the current fan state, so it left your fans alone." }
        if raw.contains("thermal manager") { return "macOS didn't let go of the fans yet. Please try again." }
        if raw.contains("not installed") { return "Fan control isn't turned on yet." }
        return raw
    }
}

struct StatusBanner: View {
    enum Kind { case warning, info }
    var kind: Kind = .warning
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .warning ? Color.orange : Color.blue)
                .font(.body)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background((kind == .warning ? Color.orange : Color.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((kind == .warning ? Color.orange : Color.blue).opacity(0.3)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Turn on fan control

struct EnableControlCard: View {
    @Bindable var helper: HelperClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue.gradient)
                    .symbolEffect(.pulse, isActive: helper.isInstalling)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on fan control").font(.headline)
                    Text("FanPilot only watches until you allow it to change fan speeds. macOS will ask for your password once.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Task { await helper.installHelper() }
            } label: {
                HStack(spacing: 8) {
                    if helper.isInstalling { ProgressView().controlSize(.small) }
                    Text(helper.isInstalling ? "Waiting for your approval…" : "Turn On Fan Control")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(helper.isInstalling)
        }
        .padding(16)
        .cardBackground()
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

// MARK: - Fans

struct FanRow: View {
    var fan: FanReading
    var tint: Color = FanMode.daily.tint

    var body: some View {
        // Shown in 5% steps: fan speed jitters by about 1%, and every change would restart a text and bar
        // animation, which SwiftUI renders on the CPU. Steady speeds must produce a steady screen.
        let exact = fan.maximum > 0 ? min(1, max(0, fan.rpm / fan.maximum)) : 0
        let fraction = (exact * 20).rounded() / 20
        let tint: Color = fan.manual ? self.tint : FanMode.normal.tint
        HStack(spacing: 12) {
            SpinningFan(speed: fraction, tint: tint).frame(width: 28, height: 28)
            Text(fan.name).font(.subheadline.weight(.medium)).frame(width: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(tint.gradient)
                        .frame(width: max(8, proxy.size.width * fraction))
                        .opacity(fan.rpm < 50 ? 0.35 : 1)
                }
            }
            .frame(height: 8)
            .animation(.smooth(duration: 0.8), value: fraction)
            Text(fan.rpm < 50 ? "Resting" : "\(Int((fraction * 100).rounded()))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.smooth, value: Int((fraction * 100).rounded()))
                .frame(width: 62, alignment: .trailing)
        }
        .help("\(Int(fan.rpm.rounded())) RPM  (\(Int(fan.minimum)) to \(Int(fan.maximum)))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fan.name) fan")
        .accessibilityValue(fan.rpm < 50 ? "Resting" : "\(Int((fraction * 100).rounded())) percent")
    }
}

// MARK: - Details (hidden until asked for)

struct DetailsSection: View {
    @Bindable var monitor: Monitor
    var summary: CoolingSummary
    @State private var expanded = false
    @State private var showAllSensors = false
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.friendly) { expanded.toggle() }
            } label: {
                HStack {
                    Text("Details").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 12).padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide details" : "Show details")

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(summary.fans) { fan in
                        HStack {
                            Text(fan.name)
                            Spacer()
                            Text("\(Int(fan.rpm.rounded())) RPM").monospacedDigit().foregroundStyle(.secondary)
                            Text("(\(Int(fan.minimum))–\(Int(fan.maximum)))").font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                    Divider()
                    let sensors = monitor.state.sensors.filter { $0.kind != .other }.sorted { $0.temperature > $1.temperature }
                    let shown = showAllSensors ? sensors : Array(sensors.prefix(6))
                    Text("Hottest sensors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(shown) { sensor in
                        HStack(spacing: 10) {
                            Text(sensor.kind.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.primary.opacity(0.07), in: Capsule())
                            Text(sensor.key).font(.callout.monospaced())
                            Spacer()
                            SensorSparkline(values: monitor.sensorHistory[sensor.key, default: []]).frame(width: 60, height: 18)
                            Text("\(TemperatureUnit(rawValue: unitRaw)?.degrees(sensor.temperature) ?? Int(sensor.temperature.rounded()))°")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Thermal.textColor(sensor.temperature))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    if sensors.count > 6 {
                        Button(showAllSensors ? "Show fewer" : "Show all \(sensors.count) sensors") {
                            withAnimation(.friendly) { showAllSensors.toggle() }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardBackground()
        .clipped()
    }
}

struct SensorSparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { proxy in
            let low = values.min() ?? 0
            let span = max(1, (values.max() ?? 1) - low)
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
                                        y: proxy.size.height * (1 - CGFloat((value - low) / span)))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Explaining the modes

/// One plain sentence about the selected mode, right under the three cards.
struct ModeExplainer: View {
    var mode: FanMode
    var installed: Bool

    private var text: String {
        guard installed else { return "FanPilot is only watching right now. Turn on fan control to choose a mode." }
        switch mode {
        case .normal: return "Normal: macOS controls the fans, just like without FanPilot."
        case .daily: return "Daily: FanPilot keeps your Mac cool but quiet. Fans rest until they're needed."
        case .turbo: return "Turbo: both fans run at full speed until you pick another mode."
        }
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.4), value: text)
    }
}

/// Shown only while Daily is selected: the one extra choice that belongs to Daily mode.
struct DailyStyleControl: View {
    @Binding var config: DailyConfig
    var compact = false
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue
    @Namespace private var selection

    var body: some View {
        let unit = TemperatureUnit(rawValue: unitRaw) ?? .celsius
        let current = CoolingStyle.matching(config)
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text("How should Daily work?")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(compact ? .secondary : .primary)
            HStack(spacing: 4) {
                ForEach(CoolingStyle.allCases) { option in
                    let selected = current == option
                    Button {
                        withAnimation(.friendly) { option.apply(to: &config) }
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, compact ? 5 : 7)
                            .background {
                                if selected {
                                    Capsule().fill(FanMode.daily.tint.opacity(0.22))
                                        .overlay(Capsule().strokeBorder(FanMode.daily.tint.opacity(0.7)))
                                        .matchedGeometryEffect(id: "daily-style", in: selection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.06), in: Capsule())
            Text(current.map { "\($0.blurb) Fans start at about \(unit.degrees($0.startCelsius))\(unit.symbol)." }
                 ?? "Custom settings. You can change them in Settings > Daily Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: compact ? 12 : 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
