import SwiftUI
import UIKit

/// The dashboard's speedometer, for riding or walking to class. It uses location only after the
/// user turns it on, and then resumes each time the dashboard opens until it is turned off.
struct SpeedometerCard: View {
    var color: Color
    @State private var meter = SpeedMeter()
    @AppStorage("courseflow.dashboardSpeedometer") private var enabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        DashboardPanel {
            HStack(spacing: 8) {
                Label("时速", systemImage: "gauge.with.dots.needle.67percent").font(.headline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    if meter.isOn { meter.stop(); enabled = false } else { meter.start(); enabled = true }
                } label: {
                    Label(meter.isOn ? "停止" : "开始测速", systemImage: meter.isOn ? "stop.fill" : "location.fill")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 2).frame(minHeight: 30)
                }
                .buttonStyle(.glass).accessibilityIdentifier("dashboard-speed-toggle")
            }
            SpeedDial(speed: meter.isOn ? meter.speed : nil, scale: scale, color: meter.isOn ? color : .secondary)
                .frame(maxWidth: 280).frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: meter.speed)
            footer.frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-speedometer")
        // UI tests must not raise the location permission prompt.
        .onAppear { if enabled && !ProcessInfo.processInfo.arguments.contains("--uitesting") { meter.start() } }
        .onDisappear { meter.stop() }
    }

    /// The dial widens once this run goes faster, such as on a bus, and stays wide until it stops.
    private var scale: Double { [40.0, 80, 160].first { meter.topSpeed <= $0 } ?? 160 }

    @ViewBuilder private var footer: some View {
        switch meter.state {
        case .off: hint("用定位测量骑车或步行的速度，只在本机计算，不保存行程。", systemImage: "lock")
        case .locating: hint("正在定位…", systemImage: "location")
        case .unavailable: hint("暂时没有定位信号，到室外开阔处会自动恢复。", systemImage: "location.slash")
        case .denied: settingsHint("课序没有使用位置的权限，可在「设置」中允许。")
        case .approximate: settingsHint("需要打开「精确位置」才能测速。")
        case .measuring:
            HStack(spacing: 0) {
                stat("最高", value: "\(Int(meter.topSpeed.rounded())) km/h")
                Divider().frame(height: 34)
                stat("里程", value: meter.distance < 1000 ? "\(Int(meter.distance)) m" : (meter.distance / 1000).formatted(.number.precision(.fractionLength(1))) + " km")
            }
        }
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    private func settingsHint(_ text: String) -> some View {
        VStack(spacing: 10) {
            hint(text, systemImage: "location.slash")
            Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// A 240° dial: the arc fills in the course color up to the current speed, over ticks for the scale.
struct SpeedDial: View {
    /// km/h; nil shows no reading.
    var speed: Double?
    /// The speed at the end of the dial, in km/h.
    var scale: Double
    var color: Color
    private static let startAngle = 150.0
    private static let sweep = 240.0
    /// The arc's open bottom leaves room to spare, so the dial is shorter than it is wide.
    private static let heightRatio = 0.82

    var body: some View {
        let fraction = min(max((speed ?? 0) / scale, 0), 1)
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height / Self.heightRatio)
            let line = side * 0.065
            ZStack {
                arc(1, inset: line / 2).stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: line, lineCap: .round))
                arc(fraction, inset: line / 2)
                    .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(Self.startAngle), endAngle: .degrees(Self.startAngle + Self.sweep)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                if speed != nil {
                    // Rotating an offset dot keeps it on the arc while it animates.
                    Circle().fill(.white).frame(width: line * 0.5, height: line * 0.5)
                        .shadow(color: .black.opacity(0.25), radius: 1.5)
                        .offset(y: -(side - line) / 2)
                        .rotationEffect(.degrees(Self.sweep * fraction - Self.sweep / 2))
                }
                ticks(side: side, line: line)
                VStack(spacing: 0) {
                    Text(speed.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: side * 0.3, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: speed ?? 0))
                    Text("km/h").font(.system(size: side * 0.075, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                .offset(y: side * 0.05)
            }
            .frame(width: side, height: side)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .aspectRatio(1 / Self.heightRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时速")
        .accessibilityValue(speed.map { "每小时 \(Int($0.rounded())) 公里" } ?? "暂无读数")
    }

    private func arc(_ fraction: Double, inset: CGFloat) -> some Shape {
        Circle().inset(by: inset).trim(from: 0, to: Self.sweep / 360 * fraction).rotation(.degrees(Self.startAngle))
    }

    /// Twenty steps across the scale, labeled every fifth.
    private func ticks(side: CGFloat, line: CGFloat) -> some View {
        let start = Self.startAngle, sweep = Self.sweep, top = Int(scale), steps = 20
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2 - line - side * 0.035
            func point(_ radius: CGFloat, _ angle: Double) -> CGPoint { CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)) }
            for step in 0...steps {
                let major = step % 5 == 0
                let angle = Angle.degrees(start + sweep * Double(step) / Double(steps)).radians
                let length = side * (major ? 0.045 : 0.022)
                var tick = Path()
                tick.move(to: point(outer, angle))
                tick.addLine(to: point(outer - length, angle))
                context.stroke(tick, with: .color(major ? Color.secondary : Color.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: major ? 2 : 1, lineCap: .round))
                if major {
                    let label = context.resolve(Text("\(top * step / steps)").font(.system(size: side * 0.05, weight: .semibold, design: .rounded)).foregroundStyle(Color.secondary))
                    context.draw(label, at: point(outer - length - side * 0.06, angle))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
