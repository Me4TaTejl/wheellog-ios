import SwiftUI
import UIKit

enum ClassicTypeface {
    static let name = "Wheellog-Regular"

    static func font(_ size: CGFloat) -> Font {
        .custom(name, fixedSize: size)
    }
}

enum ClassicNumber {
    static func text(_ value: Double?, places: Int = 0, minimum: Int = 1) -> String {
        guard let value else { return "—" }
        let digits = minimum + (places == 0 ? 0 : places + 1)
        return String(format: "%0\(digits).\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func reading(_ value: Double?, places: Int = 0, unit: String) -> String {
        text(value, places: places) + (unit == "%" ? "" : " ") + unit
    }
}

enum DialQuantity: String, CaseIterable, Identifiable {
    case speed = "Скорость"
    case current = "Ток"
    case pwm = "PWM"
    case phaseCurrent = "Фазный ток"
    var id: Self { self }

    func value(_ frame: Telemetry) -> Double? {
        switch self {
        case .speed: frame.speed
        case .current: frame.current
        case .pwm: frame.pwm
        case .phaseCurrent: frame.phaseCurrent
        }
    }

    var scale: Double {
        switch self {
        case .speed: 60
        case .current: 100
        case .pwm: 100
        case .phaseCurrent: 200
        }
    }
}

struct Dashboard: View {
    @ObservedObject var wheel: WheelConnection
    @AppStorage("classicDialQuantity") private var dialQuantity = DialQuantity.speed
    @AppStorage("classicPWMSummary") private var showPWM = true
    @AppStorage("classicSwapSpeedPWM") private var swapSpeedPWM = false

    private var rows: [[Readout]] {
        let frame = wheel.telemetry
        let peaks = wheel.extrema
        return [
            [.init("Ток", frame.current, 1, "А"), .init("Макс. ток", peaks.current, 1, "А")],
            [.init("PWM", frame.pwm, 2, "%"), .init("Макс. PWM", peaks.pwm, 2, "%")],
            [.init("Мощность", frame.power, 0, "Вт"), .init("Макс. мощность", peaks.power, 0, "Вт")],
            [.init("Темп. мотора", frame.motorTemperature, 0, "°C"), .init("Макс. скорость", peaks.speed, 1, "км/ч")]
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let dialSize = min(max(1, width - 18), max(1, geometry.size.height * 0.63))
            let readingSize = max(1, min(width * 0.079, geometry.size.height * 0.052))
            let readings = rows
            VStack(spacing: 0) {
                ClassicSpeedometer(frame: wheel.telemetry, extrema: wheel.extrema, model: wheel.modelName,
                                   quantity: dialQuantity, showPWM: showPWM, swapSpeedPWM: swapSpeedPWM)
                    .frame(width: dialSize, height: dialSize * 0.80)
                    .padding(.top, 9)
                VStack(spacing: 0) {
                    ForEach(readings.indices, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(readings[row]) { value in
                                VStack(spacing: 4) {
                                    Text(value.display)
                                        .font(ClassicTypeface.font(readingSize))
                                        .foregroundStyle(RideColors.instrument)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                    Text(value.title)
                                        .font(ClassicTypeface.font(readingSize * 0.59))
                                        .foregroundStyle(RideColors.muted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.66)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.top, 3)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if wheel.demo || wheel.state != .live {
                Text(wheel.demo ? "Демо-режим" : wheel.status)
                    .foregroundStyle(RideColors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 12)
            Text("ver \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.2.9") iOS")
                .foregroundStyle(RideColors.version)
                .fixedSize()
        }
        .font(ClassicTypeface.font(15))
        .padding(.horizontal, 13)
        .padding(.bottom, 3)
    }

    private struct Readout: Identifiable {
        let title: String
        let display: String
        var id: String { title }

        init(_ title: String, _ amount: Double?, _ places: Int, _ unit: String) {
            self.title = title
            display = ClassicNumber.reading(amount, places: places, unit: unit)
        }
    }
}

private struct ClassicSpeedometer: View {
    // Classic dial geometry follows WheelLog.Android 3.2.9 (GPL-3.0).
    let frame: Telemetry
    let extrema: RideExtrema
    let model: String
    let quantity: DialQuantity
    let showPWM: Bool
    let swapSpeedPWM: Bool

    private let segmentStep = 2.25
    private let start = 144.0
    private let end = 396.0

    var body: some View {
        Canvas { graphics, size in
            let side = size.width
            let center = CGPoint(x: side / 2, y: side / 2)
            let outerWidth = side / 8
            let innerWidth = outerWidth * 0.60
            let outer = (side - outerWidth) / 2
            let inner = outer - (outerWidth + innerWidth) / 2 - side * 0.012

            stroke(graphics, center, outer, from: start, to: end, width: outerWidth, color: RideColors.arc)
            stroke(graphics, center, inner, from: start, to: 234, width: innerWidth, color: RideColors.arc)
            stroke(graphics, center, inner, from: 306, to: end, width: innerWidth, color: RideColors.arc)

            let dial = quantity.value(frame) ?? 0
            let dialCount = steps(abs(dial) / quantity.scale, in: 112)
            let dialColor = quantity == .pwm ? pwmColor : (dial < 0 ? RideColors.dialNegative : RideColors.dialPositive)
            drawSegments(graphics, center, outer, width: outerWidth, first: 0, last: dialCount) { _ in dialColor }

            if let battery = frame.battery {
                let count = steps(battery / 100, in: 40)
                let low = steps((extrema.lowestBattery ?? battery) / 100, in: 40)
                drawSegments(graphics, center, inner, width: innerWidth, first: 0, last: count) { index in
                    index >= low ? RideColors.batteryLow : RideColors.battery
                }
                let boundary = start + Double(count) * segmentStep
                place(graphics, text: ClassicNumber.text(battery, minimum: 2) + "%", size: side * 0.042,
                      at: point(center, inner, boundary + 0.6), rotation: boundary - 180, color: RideColors.instrument)
                place(graphics, text: "true", size: side * 0.037, at: point(center, inner, start - 5),
                      rotation: start - 185, color: RideColors.instrument)
            }

            if let temperature = frame.temperature {
                let count = steps(temperature / 80, in: 40)
                drawSegments(graphics, center, inner, width: innerWidth, first: 112 - count, last: 112) { _ in RideColors.temperature }
                let boundary = end - Double(count) * segmentStep
                place(graphics, text: ClassicNumber.text(temperature) + "°C", size: side * 0.042,
                      at: point(center, inner, boundary - 2), rotation: boundary - 360, color: RideColors.instrument)
                if let maximum = extrema.temperature {
                    place(graphics, text: ClassicNumber.text(maximum) + "°C", size: side * 0.042,
                          at: point(center, inner, 310), rotation: -50, color: RideColors.instrument)
                }
            }

            drawModel(graphics, center: center, radius: inner - side * 0.037, size: side * 0.063)
            let speed = frame.speed.map(abs)
            let displayedSpeed = ClassicNumber.text(speed, places: (speed ?? 0) < 10 ? 1 : 0)
            let primary = swapSpeedPWM ? ClassicNumber.text(frame.pwm) : displayedSpeed
            place(graphics, text: primary, size: side * 0.326,
                  at: CGPoint(x: center.x, y: center.y - side * 0.009), color: swapSpeedPWM ? pwmColor : .white)

            let subheading: String
            if showPWM && !swapSpeedPWM {
                subheading = "\(ClassicNumber.text(frame.pwm, minimum: 2))% / \(ClassicNumber.text(extrema.pwm, minimum: 2))%"
            } else if swapSpeedPWM {
                subheading = "\(displayedSpeed) км/ч"
            } else {
                subheading = "км/ч"
            }
            place(graphics, text: subheading, size: side * 0.080,
                  at: CGPoint(x: center.x, y: center.y + side * 0.22), color: RideColors.instrument)
        }
        .accessibilityLabel("Скорость \(ClassicNumber.text(frame.speed.map(abs), places: 1)) км/ч")
        .accessibilityValue("PWM \(ClassicNumber.text(frame.pwm)) процентов")
    }

    private var pwmColor: Color {
        switch frame.pwm ?? 0 {
        case 90...: RideColors.dialPositive
        case 75...: RideColors.batteryLow
        default: RideColors.instrument
        }
    }

    private func steps(_ fraction: Double, in count: Int) -> Int {
        Int((min(1, max(0, fraction)) * Double(count)).rounded())
    }

    private func drawSegments(_ graphics: GraphicsContext, _ center: CGPoint, _ radius: CGFloat, width: CGFloat,
                              first: Int, last: Int, color: (Int) -> Color) {
        guard first < last else { return }
        for index in first..<last {
            let angle = start + Double(index) * segmentStep
            stroke(graphics, center, radius, from: angle, to: angle + 1.5, width: width, color: color(index))
        }
    }

    private func stroke(_ graphics: GraphicsContext, _ center: CGPoint, _ radius: CGFloat,
                        from: Double, to: Double, width: CGFloat, color: Color) {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        graphics.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
    }

    private func drawModel(_ graphics: GraphicsContext, center: CGPoint, radius: CGFloat, size: CGFloat) {
        let letters = Array(model.prefix(28)).map(String.init)
        let font = UIFont(name: ClassicTypeface.name, size: size) ?? UIFont.systemFont(ofSize: size)
        let width = letters.reduce(CGFloat.zero) { $0 + $1.size(withAttributes: [.font: font]).width }
        let fit = width > 0 ? min(1, radius * 1.0 / width) : 1
        let size = size * fit
        let fitted = font.withSize(size)
        let widths = letters.map { $0.size(withAttributes: [.font: fitted]).width }
        var offset = -widths.reduce(0, +) / 2
        for (letter, width) in zip(letters, widths) {
            let angle = Double((offset + width / 2) / radius) * 180 / .pi
            place(graphics, text: letter, size: size, at: point(center, radius, 270 + angle),
                  rotation: angle, color: RideColors.instrument)
            offset += width
        }
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    private func place(_ graphics: GraphicsContext, text: String, size: CGFloat, at point: CGPoint,
                       rotation: Double = 0, color: Color) {
        var context = graphics
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: .degrees(rotation))
        context.draw(Text(text).font(ClassicTypeface.font(size)).foregroundColor(color), at: .zero)
    }
}
