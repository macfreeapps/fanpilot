import SwiftUI
import FanCore

struct MainWindow: View {
    @Bindable var monitor: Monitor
    @Bindable var helper: HelperClient
    @Binding var config: DailyConfig

    var body: some View {
        let summary = CoolingSummary(monitor: monitor, helper: helper)
        let issue = Friendly.issue(helperError: helper.error, snapshotError: helper.snapshot.lastError, monitorError: monitor.error,
                                   anyFanManual: summary.fans.contains { $0.manual })
        ScrollView {
            VStack(spacing: 22) {
                FanHero(summary: summary, size: 240)
                    .padding(.top, 10)

                VStack(spacing: 6) {
                    Text(summary.headline)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    Text(summary.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360, minHeight: 40, alignment: .top)
                        .contentTransition(.opacity)
                }
                .animation(.smooth(duration: 0.5), value: summary.headline)
                .animation(.smooth(duration: 0.5), value: summary.detail)

                if let issue {
                    StatusBanner(message: issue)
                }

                if monitor.connected && !summary.fans.isEmpty {
                    if !helper.installed { EnableControlCard(helper: helper) }
                    ModePicker(helper: helper, config: config)
                    ModeExplainer(mode: helper.mode, installed: helper.installed)
                    if helper.installed && helper.mode == .daily {
                        DailyStyleControl(config: $config)
                    }
                }

                if !summary.fans.isEmpty {
                    VStack(spacing: 14) {
                        ForEach(summary.fans) { FanRow(fan: $0, tint: summary.tint) }
                    }
                    .padding(16)
                    .cardBackground()
                }

                DetailsSection(monitor: monitor, summary: summary)

                HStack {
                    OpenSettingsButton { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("FanPilot 1.0").font(.caption).foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
            .padding(.horizontal, 26).padding(.bottom, 22)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .animation(.friendly, value: issue)
            .animation(.friendly, value: helper.installed)
        }
        .frame(minWidth: 440, minHeight: 620)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [summary.tint.opacity(0.14), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.55))
                    .animation(.easeInOut(duration: 1.0), value: summary.tint)
            }
            .ignoresSafeArea()
        }
        .task { monitor.start() }
    }
}
