import Charts
import SwiftUI

struct TelemetryPage: View {
    @ObservedObject var wheel: WheelConnection

    var body: some View {
        ClassicScrollPage {
            LabeledContent("Модель", value: wheel.modelName)
            LabeledContent("Прошивка", value: wheel.frame?.version ?? "—")
            LabeledContent("Устройство", value: wheel.deviceName ?? "—")
            Divider()
            ForEach(Metric.allCases) { metric in
                LabeledContent(metric == .pwm ? "PWM" : metric.rawValue) {
                    let amount = metric.value(in: wheel.telemetry)
                    let estimated = [.battery, .current, .power].contains(metric) && amount != nil && !wheel.demo
                    Text((estimated ? "≈ " : "") + ClassicNumber.reading(amount, places: precision(metric), unit: metric.unit))
                        .foregroundStyle(RideColors.instrument)
                }
            }
        }
    }

    private func precision(_ metric: Metric) -> Int {
        switch metric {
        case .pwm, .trip: 2
        case .battery, .power, .temperature, .motorTemperature: 0
        default: 1
        }
    }
}

struct TrendPage: View {
    @ObservedObject var wheel: WheelConnection
    @State private var series = Metric.speed

    var body: some View {
        ClassicScrollPage {
            Picker("Показатель", selection: $series) {
                Text("Скорость").tag(Metric.speed)
                Text("Ток").tag(Metric.current)
                Text("PWM").tag(Metric.pwm)
            }
            .pickerStyle(.segmented)
            if wheel.speedHistory.isEmpty {
                Text("График появится после подключения колеса.")
                    .foregroundStyle(RideColors.instrument)
            } else {
                chart.frame(height: 260)
            }
        }
    }

    private var chart: some View {
        let end = wheel.speedHistory.last?.time ?? 0
        let metric = series
        return Chart(wheel.speedHistory) { point in
            if let value = measure(point, metric: metric) {
                LineMark(x: .value("Секунды", point.time - end), y: .value(metric.unit, value))
                    .foregroundStyle(RideColors.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: -30.0...0.0)
        .chartXAxis {
            AxisMarks(values: [-30.0, -20.0, -10.0, 0.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text("\(Int(seconds)) с")
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYAxisLabel(metric.unit, position: .topLeading)
    }

    private func measure(_ point: WheelConnection.SpeedPoint, metric: Metric) -> Double? {
        switch metric {
        case .current: point.current
        case .pwm: point.pwm
        default: point.speed
        }
    }
}

struct RideEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

struct EventPage: View {
    let events: [RideEvent]

    var body: some View {
        ClassicScrollPage {
            if events.isEmpty {
                Text("Событий пока нет.")
                    .foregroundStyle(RideColors.instrument)
            }
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.date, style: .time)
                        .foregroundStyle(RideColors.muted)
                        .fixedSize()
                    Text(event.message)
                        .foregroundStyle(RideColors.instrument)
                }
                Divider()
            }
        }
    }
}

struct ClassicSettings: View {
    @AppStorage("classicClock") private var showClock = true
    @AppStorage("classicDialQuantity") private var quantity = DialQuantity.speed
    @AppStorage("classicPWMSummary") private var showPWM = true
    @AppStorage("classicSwapSpeedPWM") private var swapSpeedPWM = false

    var body: some View {
        RideScreen(title: "Настройки экрана", showsClose: true) {
            RidePanel {
                Toggle("Часы", isOn: $showClock)
                Divider()
                Picker("Значение на дуге", selection: $quantity) {
                    ForEach(DialQuantity.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                Divider()
                Toggle("Скорость и PWM местами", isOn: $swapSpeedPWM)
                Divider()
                Toggle("PWM под скоростью", isOn: $showPWM)
                    .disabled(swapSpeedPWM)
            }
        }
    }
}

private struct ClassicScrollPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .font(ClassicTypeface.font(19))
                .frame(maxWidth: 650)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
