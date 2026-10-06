import SwiftUI
import FanCore

/// The small panel that drops down from the menu bar: just enough to see and switch modes.
struct MenuPanel: View {
    @Bindable var monitor: Monitor
    @Bindable var helper: HelperClient
    @Binding var config: DailyConfig
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let summary = CoolingSummary(monitor: monitor, helper: helper)
        let issue = Friendly.issue(helperError: helper.error, snapshotError: helper.snapshot.lastError, monitorError: monitor.error,
                                   anyFanManual: summary.fans.contains { $0.manual })
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                FanHero(summary: summary, size: 104, showsTemperature: false)
                    .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.headline)
                        .font(.system(.headline, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let temperature = summary.temperature { TemperatureReadout(temperature: temperature).scaleEffect(0.85, anchor: .leading) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.5), value: summary.headline)
            }

            if let issue { StatusBanner(message: issue) }

            if monitor.connected && !summary.fans.isEmpty {
                if helper.installed {
                    ModePicker(helper: helper, config: config, compact: true)
                    if helper.mode == .daily { DailyStyleControl(config: $config, compact: true) }
                } else {
                    Button {
                        Task { await helper.installHelper() }
                    } label: {
                        HStack(spacing: 8) {
                            if helper.isInstalling { ProgressView().controlSize(.small) } else { Image(systemName: "lock.shield.fill") }
                            Text(helper.isInstalling ? "Waiting for your approval…" : "Turn On Fan Control")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(helper.isInstalling)
                }
            }

            HStack(spacing: 14) {
                Button("Open FanPilot") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                OpenSettingsButton { Image(systemName: "gearshape") }.help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .help("Your Mac takes the fans back when FanPilot quits")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 350)
        .animation(.friendly, value: issue)
        .animation(.friendly, value: helper.installed)
        .task { monitor.start() }
    }
}
