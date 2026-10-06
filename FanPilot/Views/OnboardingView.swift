import SwiftUI
import FanCore

/// A short, friendly first-launch welcome.
struct OnboardingView: View {
    @Bindable var monitor: Monitor
    let onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            SpinningFan(speed: 0.45, tint: FanMode.daily.tint)
                .frame(width: 96, height: 96)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 6) {
                Text("Welcome to FanPilot")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("See how your Mac is doing, and choose how it keeps cool.")
                    .foregroundStyle(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            VStack(alignment: .leading, spacing: 16) {
                point("thermometer.medium", .teal, "See it at a glance", "Your Mac's temperature and fan speed, always in the menu bar.")
                    .stagger(appeared, 1)
                point("wand.and.stars", .blue, "Pick a mode", "Normal lets your Mac decide. Daily keeps things quiet and smart. Turbo cools as hard as it can.")
                    .stagger(appeared, 2)
                point("lock.shield.fill", .green, "Safe by design", "Your Mac takes the fans back whenever you quit FanPilot.")
                    .stagger(appeared, 3)
            }
            .padding(.horizontal, 6)

            if monitor.connected && monitor.state.fans.isEmpty {
                StatusBanner(kind: .info, message: "This Mac has no fans to control. FanPilot will just show its temperature.")
            }

            Button(action: onContinue) {
                Text("Get Started").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .stagger(appeared, 4)
        }
        .padding(30)
        .frame(width: 480)
        .task { monitor.start() }
        .onAppear { withAnimation(.friendly.delay(0.1)) { appeared = true } }
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    /// Fade and slide in one after another.
    func stagger(_ appeared: Bool, _ index: Int) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.friendly.delay(0.12 * Double(index)), value: appeared)
    }
}
