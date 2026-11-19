import SwiftUI

struct LiveRouteView: View {
    @ObservedObject var recorder: RouteRecorder
    @ObservedObject var wheel: WheelConnection
    @AppStorage("yandexTilesKey") private var key = ""
    @Environment(\.dismiss) private var dismiss
    @State private var following = true
    @State private var mapSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RideMap(fixes: recorder.fixes, marker: recorder.fixes.last, following: following)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            following.toggle()
                        } label: {
                            Image(systemName: following ? "location.fill" : "location")
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityLabel(following ? "Отключить слежение за позицией" : "Следить за позицией")
                        .padding(10)
                    }
                VStack(spacing: 12) {
                    RouteElevation(fix: recorder.fixes.last)
                    HStack(spacing: 12) {
                        if let start = recorder.started {
                            Text(start, style: .timer).monospacedDigit()
                            Spacer()
                            Button("Завершить", systemImage: "stop.fill", role: .destructive) { recorder.stop() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        } else {
                            Button("Начать запись", systemImage: "record.circle") {
                                following = true
                                recorder.start(seed: wheel.state == .live ? wheel.telemetry : nil)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(recorder.waitingForPermission)
                        }
                    }
                    if let status = recorder.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    if recorder.started != nil {
                        Label(wheel.state == .live ? "Телеметрия колеса записывается" : "Нет сигнала колеса · GPS записывается",
                              systemImage: wheel.state == .live ? "checkmark.circle" : "antenna.radiowaves.left.and.right.slash")
                            .font(.caption)
                            .foregroundStyle(wheel.state == .live ? Color.secondary : .red)
                    }
                }
                .padding()
                .background(RideColors.background)
            }
            .navigationTitle("GPS-маршрут")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Назад", systemImage: "chevron.left") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(key.isEmpty ? "Apple Карты" : "Яндекс Карты", systemImage: "gearshape") {
                        mapSettings = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Настройки карты")
                }
            }
            .sheet(isPresented: $mapSettings) { RouteMapSettings() }
        }
    }
}

private struct RouteMapSettings: View {
    @AppStorage("yandexTilesKey") private var key = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Подложка") {
                    LabeledContent("Текущая карта", value: key.isEmpty ? "Apple Карты" : "Яндекс Карты")
                    SecureField("Ключ Яндекс Tiles API", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Включить Яндекс Карты") {
                        key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !key.isEmpty {
                        Button("Переключить на Apple Карты") {
                            key = ""
                            dismiss()
                        }
                    }
                }
                Section {
                    Link("Кабинет разработчика Яндекса",
                         destination: URL(string: "https://developer.tech.yandex.ru/")!)
                    Link("Условия использования API",
                         destination: URL(string: "https://yandex.ru/legal/maps_api/ru/")!)
                    Link("Условия использования сервиса Яндекс.Карты",
                         destination: URL(string: "https://yandex.ru/legal/maps_termsofuse/")!)
                } footer: {
                    Text("Для Яндекс Карт нужен ключ Tiles API, подходящий для показа геопозиции в реальном времени. Ключ хранится в приложении на iPhone.")
                }
            }
            .navigationTitle("Настройки карты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}

struct RouteReview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var route: SavedRoute?
    @State private var elapsed: Double = 0
    @State private var csv: URL?
    @State private var exporting = false
    @State private var loadFailed = false
    @State private var exportFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let route {
                    let time = route.start.addingTimeInterval(elapsed)
                    let fix = route.fix(at: time)
                    VStack(spacing: 0) {
                        if !route.fixes.isEmpty {
                            RideMap(fixes: route.fixes, marker: fix)
                                .frame(height: 240)
                        }
                        ScrollView {
                            VStack(spacing: 14) {
                                timeline(route, time: time)
                                RouteElevation(fix: fix)
                                if let speed = fix?.speed {
                                    LabeledContent("Скорость GPS", value: speed.formatted(.number.precision(.fractionLength(1))) + " км/ч")
                                }
                                if let telemetry = route.telemetry(at: time) {
                                    let metrics = Metric.allCases.filter { $0.value(in: telemetry) != nil }
                                    ForEach(metrics) { metric in
                                        LabeledContent(metric.rawValue, value: "\(metric.display(telemetry)) \(metric.unit)")
                                    }
                                } else {
                                    Label("Нет телеметрии колеса в этот момент",
                                          systemImage: "antenna.radiowaves.left.and.right.slash")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                        }
                    }
                } else if loadFailed {
                    ContentUnavailableView("Не удалось открыть маршрут", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("Открываем маршрут…")
                }
            }
            .background(RideColors.background)
            .navigationTitle("Маршрут поездки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let csv {
                        ShareLink(item: csv) { Label("Поделиться CSV", systemImage: "square.and.arrow.up") }
                    } else if let route {
                        Button(exporting ? "Готовим…" : "Экспорт CSV") { export(route) }
                            .disabled(exporting)
                    }
                }
            }
            .task(id: url) {
                let url = url
                let result = await Task.detached(priority: .utility) { try? SavedRoute(url: url) }.value
                guard !Task.isCancelled else { return }
                if let result {
                    elapsed = result.end.timeIntervalSince(result.start)
                    route = result
                } else {
                    loadFailed = true
                }
            }
            .alert("Не удалось подготовить CSV", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func timeline(_ route: SavedRoute, time: Date) -> some View {
        let duration = route.end.timeIntervalSince(route.start)
        return VStack(spacing: 5) {
            if duration > 0 {
                Slider(value: $elapsed, in: 0...duration)
                    .accessibilityLabel("Положение по времени")
            }
            HStack {
                Text(time.formatted(date: .omitted, time: .standard)).monospacedDigit()
                Spacer()
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func export(_ route: SavedRoute) {
        exporting = true
        Task {
            let file = await Task.detached(priority: .utility) { try? route.exportCSV() }.value
            csv = file
            exportFailed = file == nil
            exporting = false
        }
    }
}

private struct RouteElevation: View {
    let fix: RouteFix?

    var body: some View {
        HStack(spacing: 16) {
            elevation("Высота", icon: "mountain.2", metres: fix?.altitude)
            elevation("Набор высоты", icon: "arrow.up.right", metres: fix?.ascent)
        }
    }

    private func elevation(_ title: String, icon: String, metres: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(metres.map { $0.formatted(.number.precision(.fractionLength(0))) + " м" } ?? "—")
                .font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
