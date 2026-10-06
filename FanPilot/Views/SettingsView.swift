import SwiftUI
import AppKit
import FanCore

/// Three ready-made styles for Daily mode, so nobody has to understand temperatures to tune it.
enum CoolingStyle: String, CaseIterable, Identifiable {
    case quiet, balanced, cool
    var id: String { rawValue }

    /// Named as a scale ("quieter" to "cooler") so it reads as how Daily mode leans, not as another mode.
    var title: String {
        switch self { case .quiet: "Quieter"; case .balanced: "Balanced"; case .cool: "Cooler" }
    }
    var startCelsius: Double { values.start }
    var symbol: String {
        switch self { case .quiet: "moon.fill"; case .balanced: "dial.medium.fill"; case .cool: "snowflake" }
    }
    var blurb: String {
        switch self {
        case .quiet: "Fans stay off longer and rise gently. Quietest, but your Mac runs warmer."
        case .balanced: "A good mix of quiet and cool. Recommended."
        case .cool: "Fans start earlier to keep your Mac cooler. A little louder."
        }
    }
    private var values: (start: Double, full: Double, hysteresis: Double) {
        switch self {
        case .quiet: (68, 90, 8)
        case .balanced: (60, 85, 8)
        case .cool: (52, 75, 6)
        }
    }
    func apply(to config: inout DailyConfig) {
        config.startTemp = values.start; config.fullTemp = values.full; config.releaseHysteresis = values.hysteresis
        config = config.validated()
    }
    static func matching(_ config: DailyConfig) -> CoolingStyle? {
        allCases.first { $0.values.start == config.startTemp && $0.values.full == config.fullTemp && $0.values.hysteresis == config.releaseHysteresis }
    }
}

// MARK: - Building blocks

/// A titled group of rows on a card, matching the main window.
private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(cornerRadius: 14)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 10)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .padding(24)
            .frame(width: 520, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A miniature of what will appear in the menu bar.
private struct MenuBarPreview: View {
    var icon: NSImage
    var text: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: icon)
            if let text { Text(text) }
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.friendly, value: text)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable var monitor: Monitor
    @Bindable var helper: HelperClient
    @Binding var config: DailyConfig
    @Binding var rememberMode: Bool
    @State private var message: String?

    var body: some View {
        TabView {
            GeneralTab(monitor: monitor, rememberMode: $rememberMode)
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarTab(monitor: monitor, helper: helper)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            DailyModeTab(config: $config)
                .tabItem { Label("Daily Mode", systemImage: "wand.and.stars") }
            FanControlTab(monitor: monitor, helper: helper, message: $message)
                .tabItem { Label("Fan Control", systemImage: "lock.shield") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .scenePadding(.horizontal)
        .navigationTitle("FanPilot Settings")
    }
}

// MARK: General

private struct GeneralTab: View {
    @Bindable var monitor: Monitor
    @Binding var rememberMode: Bool
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue
    @State private var launchAtLogin = HelperInstaller.launchesAtLogin
    @State private var loginMessage: String?

    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Temperature") {
                SettingsRow(symbol: "thermometer.medium", tint: .orange, title: "Show temperatures in",
                            subtitle: monitor.displayTemperature.map { "Right now your Mac is at \(unit.degrees($0))\(unit.symbol)." }) {
                    Picker("Temperature unit", selection: $unitRaw) {
                        ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
            }
            SettingsSection(title: "When FanPilot starts", footer: loginMessage) {
                SettingsRow(symbol: "power", tint: .green, title: "Open FanPilot at login",
                            subtitle: "Start in the background whenever you log in.") {
                    Toggle("Open FanPilot at login", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, value in
                            do { try HelperInstaller.setLaunchAtLogin(value); loginMessage = nil }
                            catch { loginMessage = error.localizedDescription; launchAtLogin = HelperInstaller.launchesAtLogin }
                        }
                }
                Divider()
                SettingsRow(symbol: "arrow.counterclockwise", tint: .blue, title: "Remember my last mode",
                            subtitle: "Pick up where you left off: Normal, Daily or Turbo.") {
                    Toggle("Remember my last mode", isOn: $rememberMode).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .animation(.friendly, value: unitRaw)
    }
}

// MARK: Menu bar

private struct MenuBarTab: View {
    @Bindable var monitor: Monitor
    @Bindable var helper: HelperClient
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("menuDisplay") private var menuDisplay = "temperature"
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue

    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }
    /// Exactly what the real menu-bar item shows right now.
    private var previewText: String? {
        MenuBarFormat.text(display: menuDisplay, celsius: monitor.menuTemperature.map(Double.init), rpm: monitor.menuRPM, unit: unit)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(footer: "FanPilot stays in your Dock either way, and your fans keep working as before.") {
                SettingsRow(symbol: "menubar.rectangle", tint: .blue, title: "Show FanPilot in the menu bar",
                            subtitle: "A quick look at your Mac, right at the top of the screen.") {
                    Toggle("Show FanPilot in the menu bar", isOn: $showMenuBarItem.animation(.friendly)).labelsHidden().toggleStyle(.switch)
                }
            }
            if showMenuBarItem {
                SettingsSection(title: "What it shows") {
                    VStack(spacing: 14) {
                        MenuBarPreview(icon: MenuBarIcon.image(mode: helper.mode, controlling: helper.installed), text: previewText)
                            .padding(.top, 14)
                        Picker("What the menu bar shows", selection: $menuDisplay.animation(.friendly)) {
                            Text("Icon").tag("icon")
                            Text("Temperature").tag("temperature")
                            Text("Fan speed").tag("rpm")
                            Text("Both").tag("both")
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: Cooling

private struct DailyModeTab: View {
    @Binding var config: DailyConfig
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue
    @State private var showAdvanced = false
    @Namespace private var selection

    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }
    private var style: CoolingStyle? { CoolingStyle.matching(config) }

    var body: some View {
        SettingsPage {
            SettingsSection(title: "How should Daily mode work?",
                            footer: style == nil ? "You've tuned Daily mode yourself." : "These choices only apply in Daily mode. Normal and Turbo don't use them.") {
                HStack(spacing: 10) {
                    ForEach(CoolingStyle.allCases) { card(for: $0) }
                }
                .padding(.vertical, 14)
                Divider()
                Button {
                    withAnimation(.friendly) { showAdvanced.toggle() }
                } label: {
                    HStack {
                        Text("Fine-tune").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showAdvanced {
                    VStack(spacing: 14) {
                        tempSlider("Start cooling at", celsius: $config.startTemp, range: 45...75)
                        tempSlider("Full speed at", celsius: $config.fullTemp, range: max(55, config.startTemp + 10)...95)
                        tempSlider("Hand back to macOS when this much cooler", celsius: $config.releaseHysteresis, range: 4...15, isDifference: true)
                        stepperRow("React after this long above the start temperature", value: $config.engageDelay, range: 1...10, step: 1)
                        stepperRow("Hand back after this long cooler", value: $config.releaseDelay, range: 10...120, step: 5)
                        percentSlider("Slow down by", value: $config.rampDownRate, range: 0.01...0.10)
                        HStack {
                            Spacer()
                            Button("Reset to recommended") { withAnimation(.friendly) { config = DailyConfig() } }
                        }
                    }
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.friendly, value: showAdvanced)
    }

    private func card(for option: CoolingStyle) -> some View {
        let selected = style == option
        return Button {
            withAnimation(.friendly) { option.apply(to: &config) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? FanMode.daily.tint : .secondary)
                Text(option.title).font(.headline)
                Text(option.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04))
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FanMode.daily.tint.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FanMode.daily.tint.opacity(0.75), lineWidth: 1.5))
                            .matchedGeometryEffect(id: "style", in: selection)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(option.title). \(option.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A slider whose stored value is Celsius but which is read and moved in the chosen unit.
    private func tempSlider(_ title: String, celsius: Binding<Double>, range: ClosedRange<Double>, isDifference: Bool = false) -> some View {
        let unit = self.unit
        let toShown: (Double) -> Double = { isDifference ? unit.convertDifference($0) : unit.convert($0) }
        let toCelsius: (Double) -> Double = { isDifference ? unit.toCelsiusDifference($0) : unit.toCelsius($0) }
        let shown = Binding<Double>(get: { toShown(celsius.wrappedValue) }, set: { celsius.wrappedValue = toCelsius($0.rounded()) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(toShown(celsius.wrappedValue).rounded())) \(unit.symbol)").monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(value: shown, in: toShown(range.lowerBound)...toShown(range.upperBound), step: 1)
                .accessibilityLabel(title)
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value.wrappedValue) s").monospacedDigit().foregroundStyle(.secondary)
            Stepper(title, value: value, in: range, step: step).labelsHidden()
        }
    }

    private func percentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))% per second").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(title)
        }
    }
}

// MARK: Fan control

private struct FanControlTab: View {
    @Bindable var monitor: Monitor
    @Bindable var helper: HelperClient
    @Binding var message: String?
    @State private var helperStatus = HelperInstaller.status

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Fan control",
                            footer: "FanPilot uses a small helper to change fan speeds. It always hands the fans back to macOS when FanPilot quits.") {
                SettingsRow(symbol: helper.installed ? "checkmark.shield.fill" : "lock.shield.fill",
                            tint: helper.installed ? .green : .orange,
                            title: helper.installed ? "Fan control is on" : "Fan control is off",
                            subtitle: helper.installed ? "You can choose Daily or Turbo mode." : "FanPilot can only watch until you turn it on.") {
                    Text(helperStatus).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    Button(helper.installed ? "Update Helper" : "Turn On Fan Control") {
                        Task {
                            await helper.installHelper()
                            helperStatus = HelperInstaller.status
                            if let error = helper.error { message = Friendly.message(for: error) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(helper.installed ? .gray : .accentColor)
                    .disabled(helper.isInstalling)
                    if helper.isInstalling { ProgressView().controlSize(.small) }
                    if helper.installed {
                        Button("Remove", role: .destructive) {
                            Task {
                                if let error = await helper.uninstallHelper() { message = error }
                                helperStatus = HelperInstaller.status
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            SettingsSection(title: "Help") {
                SettingsRow(symbol: "doc.text.magnifyingglass", tint: .gray, title: "Save a report",
                            subtitle: "A technical file you can send when asking for help.") {
                    Button("Save Report…") { exportDiagnostics() }
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .animation(.friendly, value: message)
        .animation(.friendly, value: helper.installed)
        .onChange(of: helper.installed) { _, _ in helperStatus = HelperInstaller.status }
    }

    private func exportDiagnostics() {
        Task {
            do {
                let data = try await monitor.diagnosticsData()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "FanPilot-report.json"
                panel.allowedContentTypes = [.json]
                if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); message = "Report saved." }
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: About

private struct AboutTab: View {
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue
    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0") (build \(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("FanPilot").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(versionText).font(.callout).foregroundStyle(.secondary)
                Text("Made by @tarudesu").font(.callout.weight(.medium)).padding(.top, 2)
                Text("See how your Mac is doing, and choose how it keeps cool.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            SettingsSection(title: "Good to know") {
                SettingsRow(symbol: "lock.shield.fill", tint: .green, title: "Safe by design",
                            subtitle: "Your Mac takes the fans back whenever you quit FanPilot or it stops responding.") { EmptyView() }
                Divider()
                SettingsRow(symbol: "thermometer.medium", tint: .orange, title: "Maximum cooling is always on call",
                            subtitle: "At \(unit.degrees(95))\(unit.symbol) the fans go to full speed, whichever mode you chose.") { EmptyView() }
                Divider()
                SettingsRow(symbol: "doc.text.fill", tint: .gray, title: "Free and open source",
                            subtitle: "Released under the MIT License.") { EmptyView() }
            }
        }
    }
}
