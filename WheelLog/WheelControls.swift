import SwiftUI

struct WheelControls: View {
    @ObservedObject var wheel: WheelConnection
    @AppStorage("strobeRate") private var strobeRate = 1.0

    private var canSetPedals: Bool {
        wheel.canControl && !wheel.strobe && wheel.pendingPedalMode == nil &&
            abs(wheel.telemetry.speed ?? .infinity) < 1
    }

    var body: some View {
        RideScreen(title: "Колесо", showsClose: true) {
            RidePanel {
                HStack(alignment: .firstTextBaseline) {
                    Text("Veteran Sherman S").font(.title3.bold())
                    Spacer()
                    if let version = wheel.frame?.version {
                        Text(version).font(.system(.caption, design: .monospaced)).foregroundStyle(RideColors.accent)
                    }
                }
                Text(wheel.status)
                    .font(.subheadline)
                    .foregroundStyle(RideColors.muted)
                if let name = wheel.deviceName {
                    LabeledContent("Имя Bluetooth", value: name)
                    Button("Отключить", role: .destructive) { wheel.disconnect() }
                        .buttonStyle(.bordered)
                } else {
                    scanControl
                    ForEach(wheel.devices) { device in
                        Button { wheel.connect(device) } label: {
                            HStack {
                                Image(systemName: device.preferred ? "checkmark.circle" : "dot.radiowaves.left.and.right")
                                Text(device.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if device.rssi != 127 {
                                    Text("\(device.rssi) dBm")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(RideColors.muted)
                                }
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                    }
                    Toggle("Демо-режим", isOn: Binding(get: { wheel.demo }, set: wheel.setDemo))
                        .tint(RideColors.accent)
                }
            }
            headlight
            settings
        }
    }

    @ViewBuilder
    private var scanControl: some View {
        if wheel.state == .scanning {
            Button("Остановить поиск") { wheel.stopScan() }
                .buttonStyle(.bordered)
        } else {
            Button { wheel.scan() } label: {
                Label("Найти Sherman S", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
        }
    }

    private var headlight: some View {
        RidePanel {
            Label("Фара", systemImage: "headlight.low.beam")
                .font(.headline)
            HStack {
                Button("Включить") { wheel.setLight(true) }
                Button("Выключить") { wheel.setLight(false) }
            }
            .buttonStyle(.bordered)
            .disabled(!wheel.canControl || wheel.strobe)

            Divider()

            Picker("Частота вспышек", selection: $strobeRate) {
                Text("0,5 Гц").tag(0.5)
                Text("1 Гц").tag(1.0)
                Text("2 Гц").tag(2.0)
            }
            .pickerStyle(.segmented)
            .disabled(wheel.strobe)

            Button {
                if wheel.strobe { wheel.stopStrobe() }
                else { wheel.startStrobe(hz: strobeRate) }
            } label: {
                Label(wheel.strobe ? "Остановить стробоскоп" : "Включить стробоскоп",
                      systemImage: wheel.strobe ? "stop.circle" : "bolt.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(wheel.strobe ? .orange : RideColors.accent)
            .foregroundStyle(.black)
            .disabled(!wheel.canControl && !wheel.strobe)

            Text("Частота зависит от отклика Bluetooth. При остановке приложение возвращает последнюю выбранную команду фары, по умолчанию — постоянный свет.")
                .font(.footnote)
                .foregroundStyle(RideColors.muted)
        }
    }

    private var settings: some View {
        RidePanel {
            Text("Настройки колеса").font(.headline)
            LabeledContent("Режим педалей", value: wheel.frame?.pedalMode?.rawValue ?? "—")
            HStack(spacing: 5) {
                ForEach(PedalMode.allCases) { mode in
                    Button(mode.rawValue) { wheel.setPedals(mode) }
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                        .disabled(wheel.frame?.pedalMode == mode)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!canSetPedals)
            if wheel.canControl && abs(wheel.telemetry.speed ?? .infinity) >= 1 {
                Text("Остановите колесо, чтобы изменить режим педалей.")
                    .font(.footnote)
                    .foregroundStyle(RideColors.muted)
            }
            Divider()
            LabeledContent("Порог сигнала", value: speedSetting(wheel.frame?.speedAlarm))
            LabeledContent("Подъём педалей", value: speedSetting(wheel.frame?.tiltBack))
            if let message = wheel.commandStatus {
                Text(message).font(.footnote).foregroundStyle(RideColors.muted)
            }
        }
    }

    private func speedSetting(_ speed: Double?) -> String {
        guard wheel.state == .live, let speed else { return "—" }
        return "\(speed.formatted(.number.precision(.fractionLength(1)))) км/ч"
    }
}
