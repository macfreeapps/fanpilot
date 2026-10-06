import SwiftUI
import FanCore

@main struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @State private var monitor: Monitor
    @State private var helper: HelperClient
    @State private var showingOnboarding = false
    @State private var config = DailyConfig()
    @AppStorage("rememberMode") private var rememberMode = true
    @AppStorage("menuDisplay") private var menuDisplay = "temperature"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue
    init() {
        let monitor = Monitor()
        let helper = HelperClient()
        _monitor = State(initialValue: monitor)
        _helper = State(initialValue: helper)
        let savedConfig = UserDefaults.standard.data(forKey: "dailyConfig").flatMap { try? JSONDecoder().decode(DailyConfig.self, from: $0) } ?? DailyConfig()
        _config = State(initialValue: savedConfig.validated())
        AppLifecycle.helper = helper
        monitor.start()
        let defaults = UserDefaults.standard
        let shouldRemember = defaults.object(forKey: "rememberMode") == nil || defaults.bool(forKey: "rememberMode")
        if !shouldRemember { defaults.set(FanMode.normal.rawValue, forKey: "lastMode") }
        let hasPriorPreferences = defaults.object(forKey: "lastMode") != nil || defaults.object(forKey: "dailyConfig") != nil
        _showingOnboarding = State(initialValue: !defaults.bool(forKey: "hasSeenOnboarding") && !hasPriorPreferences)
    }
    var body: some Scene {
        WindowGroup("FanPilot", id: "main") {
            MainWindow(monitor: monitor, helper: helper, config: $config)
                .sheet(isPresented: $showingOnboarding) {
                    OnboardingView(monitor: monitor) {
                        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
                        showingOnboarding = false
                    }
                }
        }
        .defaultSize(width: 480, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FanPilot") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Made by @tarudesu", attributes: [
                            .font: NSFont.systemFont(ofSize: 12),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()
                        ])
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuPanel(monitor: monitor, helper: helper, config: $config)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: MenuBarIcon.image(mode: helper.mode, controlling: helper.installed))
                // One text item: a menu-bar label shows only the first, so "both" is a single string.
                if let text = MenuBarFormat.text(display: menuDisplay, celsius: monitor.menuTemperature.map(Double.init),
                                                 rpm: monitor.menuRPM, unit: TemperatureUnit(rawValue: unitRaw) ?? .celsius) {
                    Text(text)
                }
            }
        }.menuBarExtraStyle(.window)
            .onChange(of: config) { _, next in
                if let data = try? JSONEncoder().encode(next.validated()) { UserDefaults.standard.set(data, forKey: "dailyConfig") }
                if helper.mode == .daily && helper.installed { helper.setMode(.daily, config: next) }
            }
        Settings { SettingsView(monitor: monitor, helper: helper, config: $config, rememberMode: $rememberMode) }
            .windowResizability(.contentSize)
    }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static var helper: HelperClient?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let helper = Self.helper else { return .terminateNow }
        // Restoring system control is the helper's job, and it also does it on connection loss or
        // heartbeat timeout, so never let a slow or missing helper keep the app from quitting.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        helper.restore { reply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply() }
        return .terminateLater
    }
}
