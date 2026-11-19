import Charts
import SwiftUI

struct Dashboard: View {
    @ObservedObject var wheel: WheelConnection
    @ObservedObject var library: RideLibrary
    var openWheel: () -> Void

    private let metrics: [Metric] = [.pwm, .power, .battery, .voltage, .temperature,
                                     .trip, .phaseCurrent, .current, .odometer]
    @Environment(\.dynamicTypeSize) private var typeSize
    private var columnCount: Int { typeSize.isAccessibilitySize ? 2 : 3 }

    var body: some View {
        RideScreen(title: "WheelLog") {
            Button(action: openWheel) {
                HStack(spacing: 11) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(wheel.state == .live || wheel.demo ? RideColors.accent : RideColors.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(wheel.demo ? "Демо-поездка" : ShermanProtocol.model)
                            .font(.headline)
                        Text(wheel.demo ? "Имитация телеметрии" : wheel.status)
                            .font(.subheadline)
                            .foregroundStyle(RideColors.muted)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(RideColors.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RideColors.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button {
                    if library.logging { library.stopLog() }
                    else { library.startLog(demo: wheel.demo) }
                } label: {
                    Label(library.logging ? "Завершить лог" : "Записать CSV",
                          systemImage: library.logging ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(library.logging ? .red : RideColors.accent)
                .foregroundStyle(library.logging ? .white : .black)
                .controlSize(.large)
                .disabled(!library.logging && !wheel.demo && wheel.state != .live)
                if let start = library.recordingStarted {
                    Text(start, style: .timer)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Время записи")
                }
            }

            if let error = library.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }

            RidePanel {
                SpeedDial(speed: wheel.telemetry.speed)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount), spacing: 8) {
                ForEach(metrics) { metric in
                    metricCard(metric)
                }
            }

            if !wheel.speedHistory.isEmpty {
                RidePanel {
                    Text("Скорость за 30 секунд").font(.headline)
                    speedChart
                }
            }
        }
    }

    private func metricCard(_ metric: Metric) -> some View {
        let value = metric.display(wheel.telemetry)
        let approximate = [.power, .current, .battery].contains(metric) && !wheel.demo && value != "—"
        return VStack(alignment: .leading, spacing: 6) {
            Text(metric.rawValue)
                .font(.caption)
                .foregroundStyle(RideColors.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text((approximate ? "≈" : "") + value)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(metric.unit)
                    .font(.caption2)
                    .foregroundStyle(RideColors.muted)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RideColors.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var speedChart: some View {
        let end = wheel.speedHistory.last?.time ?? 0
        let highest = wheel.speedHistory.map(\.speed).max() ?? 0
        return Chart(wheel.speedHistory) { point in
            LineMark(x: .value("Секунды", point.time - end), y: .value("км/ч", point.speed))
                .foregroundStyle(RideColors.accent)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(domain: -30.0...0.0)
        .chartYScale(domain: 0...max(20, (highest / 10).rounded(.up) * 10))
        .chartXAxis {
            AxisMarks(values: [-30.0, -15.0, 0.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text("\(Int(seconds)) c") }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 115)
    }
}

private struct SpeedDial: View {
    let speed: Double?

    var body: some View {
        let progress = min(1, max(0, abs(speed ?? 0) / 100))
        ZStack {
            Circle()
                .trim(from: 0, to: 0.74)
                .stroke(RideColors.line, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(137))
            Circle()
                .trim(from: 0, to: CGFloat(0.74 * progress))
                .stroke(RideColors.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(137))
            VStack(spacing: 3) {
                Text("Скорость").font(.subheadline).foregroundStyle(RideColors.muted)
                Text(speed.map { abs($0).formatted(.number.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(size: 63, weight: .semibold, design: .monospaced))
                    .tracking(-5)
                    .foregroundStyle(RideColors.accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("км/ч").font(.callout).foregroundStyle(RideColors.muted)
            }
            .padding(24)
        }
        .frame(width: 193, height: 193)
        .padding(6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
