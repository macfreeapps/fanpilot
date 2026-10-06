import SwiftUI
import FanCore

// MARK: - The fan itself

struct FanBlades: Shape {
    var count = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for index in 0..<count {
            var blade = Path()
            // A swept paddle: fairly straight leading edge, full trailing edge, rounded tip.
            blade.move(to: CGPoint(x: r * 0.13, y: -r * 0.03))
            blade.addCurve(to: CGPoint(x: r * 0.93, y: -r * 0.33),
                           control1: CGPoint(x: r * 0.38, y: -r * 0.05), control2: CGPoint(x: r * 0.70, y: -r * 0.16))
            blade.addQuadCurve(to: CGPoint(x: r * 0.94, y: -r * 0.10), control: CGPoint(x: r * 1.01, y: -r * 0.26))
            blade.addCurve(to: CGPoint(x: r * 0.13, y: r * 0.20),
                           control1: CGPoint(x: r * 0.80, y: r * 0.10), control2: CGPoint(x: r * 0.38, y: r * 0.30))
            blade.closeSubpath()
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: Double(index) * 2 * .pi / Double(count))
            path.addPath(blade, transform: transform)
        }
        return path
    }
}

/// Hosts the blades in Core Animation so rotation runs in the render server. The blades are drawn once
/// into a bitmap (gradient and outline included) and that texture is rotated; a rotating gradient layer
/// with a shape mask would force an offscreen render pass on every frame.
private final class BladesNSView: NSView {
    private let spin = CALayer()
    private var level = -1
    private var tint = NSColor.systemBlue
    private var renderedKey = ""

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(spin)
        spin.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spin.frame = bounds
        CATransaction.commit()
        renderBlades(fade: false)
    }

    private func renderBlades(fade: Bool) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(Int(bounds.width * scale))x\(Int(bounds.height * scale))-\(tint.description)"
        guard key != renderedKey else { return }
        renderedKey = key
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)   // path is y-down
        let path = FanBlades().path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let colors = [rgb.withAlphaComponent(0.95).cgColor, rgb.withAlphaComponent(0.55).cgColor] as CFArray
        context.saveGState()
        context.addPath(path); context.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.width, y: bounds.height), options: [])
        }
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if fade {
            let transition = CATransition(); transition.type = .fade; transition.duration = 0.5
            spin.add(transition, forKey: "tint")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spin.contents = context.makeImage()
        spin.contentsScale = scale
        CATransaction.commit()
    }

    private var currentAngle: Double {
        (spin.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (spin.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
    }

    func apply(speed: Double, tint newTint: NSColor, animated: Bool) {
        if newTint != tint { tint = newTint; renderBlades(fade: true) }

        let newLevel = (!animated || speed < 0.01) ? 0 : max(1, Int((speed * 6).rounded()))
        guard newLevel != level else { return }
        let wasSpinning = level > 0
        level = newLevel
        let angle = currentAngle
        spin.removeAnimation(forKey: "spin")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spin.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        if newLevel == 0 {
            guard animated, wasSpinning else { return }
            // Wind down: coast a little further while slowing to a stop.
            let stop = CABasicAnimation(keyPath: "transform.rotation.z")
            stop.fromValue = angle; stop.toValue = angle + 0.9
            stop.duration = 1.4; stop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spin.setValue(angle + 0.9, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            spin.add(stop, forKey: "spin")
            return
        }
        // Visual speed: calm at low RPM, brisk at full speed (not the real, strobing rotation rate).
        let degreesPerSecond = 70 + 650 * Double(newLevel) / 6
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = angle; turn.toValue = angle + 2 * Double.pi
        turn.duration = 360 / degreesPerSecond
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.add(turn, forKey: "spin")
    }
}

private struct BladesView: NSViewRepresentable {
    var speed: Double
    var tint: Color
    var animated: Bool

    func makeNSView(context: Context) -> BladesNSView { BladesNSView() }
    func updateNSView(_ view: BladesNSView, context: Context) {
        view.apply(speed: speed, tint: NSColor(tint), animated: animated)
    }
}

struct SpinningFan: View {
    /// Fan speed as a share of its maximum, 0...1.
    var speed: Double
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.28), lineWidth: 2)
            Circle().fill(tint.opacity(0.08)).padding(2)
            BladesView(speed: speed, tint: tint, animated: !reduceMotion)
            Hub(tint: tint)
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
        .accessibilityHidden(true)
    }
}

private struct Hub: View {
    var tint: Color
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height) * 0.26
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

// MARK: - Temperature gauge

struct TemperatureGauge: View {
    var temperature: Double?
    var lineWidth: CGFloat = 12

    var body: some View {
        // Whole degrees only: a continuously drifting value would restart the animation every second
        // and keep the window redrawing for no visible benefit.
        let degrees = temperature.map { Double(Int($0.rounded())) }
        let fraction = degrees.map(Thermal.fraction) ?? 0
        let color = degrees.map(Thermal.color) ?? .secondary
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.primary.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
        }
        .animation(.smooth(duration: 0.7), value: degrees)
    }
}

// MARK: - Hero: gauge + fan + the numbers that matter

struct FanHero: View {
    var summary: CoolingSummary
    var size: CGFloat = 230
    var showsTemperature = true

    var body: some View {
        ZStack {
            // The glow and the gauge animate on their own schedule; compositing them as one Metal
            // layer keeps those animations off the CPU.
            ZStack {
            // A soft glow behind the fan that matches the current mode.
            Circle()
                .fill(RadialGradient(colors: [summary.tint.opacity(summary.isResting ? 0.10 : 0.28), .clear], center: .center, startRadius: size * 0.1, endRadius: size * 0.62))
                .frame(width: size * 1.25, height: size * 1.25)
                .animation(.easeInOut(duration: 0.8), value: summary.isResting)
                .animation(.easeInOut(duration: 0.8), value: summary.tint)
            TemperatureGauge(temperature: summary.temperature, lineWidth: max(6, size * 0.05))
                .frame(width: size, height: size)
            }
            .drawingGroup()
            SpinningFan(speed: summary.averageSpeed, tint: summary.tint)
                .frame(width: size * 0.62, height: size * 0.62)
            if showsTemperature, let temperature = summary.temperature {
                TemperatureReadout(temperature: temperature)
                    .offset(y: size * 0.40)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.headline)
    }
}

struct TemperatureReadout: View {
    var temperature: Double
    @AppStorage(TemperatureUnit.storageKey) private var unitRaw = TemperatureUnit.regionDefault.rawValue

    var body: some View {
        let unit = TemperatureUnit(rawValue: unitRaw) ?? .celsius
        let degrees = unit.degrees(temperature)                 // what is shown
        let celsius = Double(Int(temperature.rounded()))        // what the wording and colour are based on
        HStack(spacing: 6) {
            Text("\(degrees)\(unit.symbol)")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(degrees)))
            Text(Thermal.word(celsius))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Thermal.textColor(celsius))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.background.secondary, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .animation(.smooth(duration: 0.5), value: degrees)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(degrees) degrees \(unit.title), \(Thermal.word(celsius))")
    }
}
