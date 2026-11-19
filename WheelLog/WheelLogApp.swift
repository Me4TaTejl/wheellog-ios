import SwiftUI
import UIKit

@main
@MainActor
struct WheelLogApp: App {
    @StateObject private var wheel = WheelConnection()
    @StateObject private var library = RideLibrary()
    @StateObject private var camera = CameraModel()
    @StateObject private var route = RouteRecorder()

    var body: some Scene {
        WindowGroup {
            ClassicShell(wheel: wheel, library: library, camera: camera, route: route)
                .preferredColorScheme(.dark)
        }
    }
}

enum RideColors {
    static let background = rgb(0x141A28)
    static let surface = rgb(0x272E3F)
    static let accent = rgb(0xFF5722)
    static let instrument = rgb(0xBDBDBD)
    static let muted = rgb(0x777A7F)
    static let version = rgb(0x515863)
    static let arc = rgb(0x080A0F)
    static let battery = rgb(0x01BF50)
    static let batteryLow = rgb(0xFFCC00)
    static let temperature = rgb(0x00FFFF)
    static let dialPositive = rgb(0xA80909)
    static let dialNegative = rgb(0x209100)
    static let line = Color.white.opacity(0.13)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}

@MainActor
private struct ClassicShell: View {
    private enum Page: String, CaseIterable, Identifiable {
        case instruments = "Приборы"
        case details = "Параметры"
        case rides = "Поездки"
        case events = "Журнал событий"
        var id: Self { self }
    }

    private enum Cover: String, Identifiable {
        case camera, wheel, settings, route
        var id: Self { self }
    }

    @ObservedObject var wheel: WheelConnection
    @ObservedObject var library: RideLibrary
    @ObservedObject var camera: CameraModel
    @ObservedObject var route: RouteRecorder
    @Environment(\.scenePhase) private var phase
    @AppStorage("classicClock") private var showClock = true
    @State private var page = Page.instruments
    @State private var cover: Cover?
    @State private var events = [RideEvent]()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if wheel.showingLastReading {
                Label("Нет сигнала · последние показания", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.08))
            }
            TabView(selection: $page) {
                Dashboard(wheel: wheel).tag(Page.instruments)
                TelemetryPage(wheel: wheel).tag(Page.details)
                LibraryView(library: library, camera: camera) { cover = .route }.tag(Page.rides)
                EventPage(events: events).tag(Page.events)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            pageIndicator
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RideColors.background.ignoresSafeArea())
        .tint(RideColors.accent)
        .onAppear {
            wheel.onSample = { [weak library, weak route] frame, demo, time in
                if !demo { route?.append(frame, at: time) }
                library?.append(frame, demo: demo, time: time, fix: demo ? nil : route?.fixForLog(at: time))
            }
            wheel.onTelemetryLost = { [weak route] time in route?.wheelLost(at: time) }
            wheel.onSourceEnded = { [weak library] in library?.stopLog() }
            route.onFileChange = { [weak library] url in library?.setActiveRoute(url) }
            camera.onVideoSaved = { [weak library] in library?.refresh() }
            updateCamera(wheel.telemetry)
            updateIdleTimer()
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--demo") { wheel.setDemo(true) }
            #endif
        }
        .onReceive(wheel.$telemetry) { updateCamera($0) }
        .onChange(of: wheel.showingLastReading) { _, _ in updateCamera(wheel.telemetry) }
        .onChange(of: wheel.strobe) { _, _ in updateIdleTimer() }
        .onChange(of: camera.recording) { _, _ in updateIdleTimer() }
        .onChange(of: wheel.status) { _, status in addEvent(status) }
        .onChange(of: wheel.commandStatus) { _, status in
            if let status { addEvent(status) }
        }
        .onChange(of: library.logging) { _, logging in
            addEvent(logging ? "Запись CSV началась" : "Запись CSV завершена")
        }
        .onChange(of: route.started) { _, start in
            addEvent(start == nil ? "Запись GPS завершена" : "Запись GPS началась")
        }
        .onChange(of: library.errorMessage) { _, message in
            if let message { addEvent(message) }
        }
        .onChange(of: camera.latestVideo) { _, url in
            if url != nil { addEvent("Видео сохранено") }
        }
        .fullScreenCover(item: $cover, onDismiss: { camera.close() }) { item in
            switch item {
            case .wheel:
                WheelControls(wheel: wheel)
            case .settings:
                ClassicSettings()
            case .camera:
                RideCameraView(wheel: wheel, camera: camera)
                    .onAppear { if phase == .active { camera.open() } }
            case .route:
                LiveRouteView(recorder: route, wheel: wheel)
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active { wheel.stopStrobe() }
            if newPhase == .background {
                camera.close()
                wheel.stopScan()
            }
            if newPhase == .active, cover == .camera {
                camera.open()
            }
            updateIdleTimer()
        }
        .alert("WheelLog", isPresented: Binding(
            get: { cover != .camera && camera.message != nil },
            set: { if !$0 { camera.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.message ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            if showClock {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.time.string(from: context.date))
                        .font(ClassicTypeface.font(25))
                        .foregroundStyle(RideColors.instrument)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel("Текущее время \(Self.time.string(from: context.date))")
                }
            }
            Spacer(minLength: 5)
            Button { cover = .camera } label: {
                Image(systemName: "video")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 38, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Камера с телеметрией")
            toolbarButton("ClassicBluetooth", title: "Найти колесо",
                          color: wheel.state == .live ? RideColors.muted : .white) {
                cover = .wheel
                if wheel.deviceName == nil && wheel.state != .scanning { wheel.scan() }
            }
            toolbarButton("ClassicWheel", title: "Подключение и настройки колеса",
                          color: wheel.state == .live || wheel.demo ? RideColors.accent : .white) {
                cover = .wheel
            }
            toolbarButton("ClassicLogging", title: library.logging ? "Завершить CSV" : "Записать CSV",
                          color: library.logging ? RideColors.accent : .white) {
                if library.logging { library.stopLog() }
                else if wheel.state == .live || wheel.demo { library.startLog(demo: wheel.demo) }
                else { cover = .wheel }
            }
            Button { cover = .route } label: {
                Image(systemName: route.started == nil ? "map" : "location.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(route.started == nil ? Color.white : RideColors.accent)
                    .frame(width: 38, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(route.started == nil ? "GPS-маршрут" : "Маршрут записывается")
            Menu {
                Button("Настройки экрана", systemImage: "slider.horizontal.3") { cover = .settings }
                Button("Настройки колеса", systemImage: "gearshape") { cover = .wheel }
                Button("Поездки", systemImage: "folder") { page = .rides }
                Button("Журнал событий", systemImage: "list.bullet") { page = .events }
                Button("Сбросить максимумы", systemImage: "arrow.counterclockwise") {
                    wheel.resetExtrema()
                    addEvent("Максимумы сброшены")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 33, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Меню")
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.leading, 13)
        .padding(.trailing, 1)
        .frame(height: 48)
    }

    private func toolbarButton(_ image: String, title: String, color: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .frame(width: 29, height: 29)
                .foregroundStyle(color)
                .frame(width: 39, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    private var pageIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Page.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { page = item }
                } label: {
                    Rectangle()
                        .fill(item == page ? RideColors.accent : RideColors.arc)
                        .frame(width: item == page ? 49 : 26, height: item == page ? 3 : 2)
                        .frame(width: 50, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(item == page ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func addEvent(_ text: String) {
        events.insert(RideEvent(message: text), at: 0)
        if events.count > 80 { events.removeLast() }
    }

    private func updateCamera(_ frame: Telemetry) {
        camera.update(.init(telemetry: frame, demo: wheel.demo, stale: wheel.showingLastReading))
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = phase == .active && (camera.recording != .idle || wheel.strobe)
    }
}

struct RideScreen<Content: View>: View {
    let title: String
    var showsClose = false
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: 650)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            .background(RideColors.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Назад", systemImage: "chevron.left") { dismiss() }
                    }
                }
            }
        }
    }
}

struct RidePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(RideColors.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(RideColors.line)
                    .allowsHitTesting(false)
            }
    }
}
