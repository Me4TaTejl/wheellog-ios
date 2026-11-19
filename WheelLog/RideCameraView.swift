import AVKit
import SwiftUI
import UIKit

@MainActor
struct RideCameraView: View {
    @ObservedObject var wheel: WheelConnection
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("overlayMetrics") private var mask = OverlayLayout.defaultMask
    @State private var showMetrics = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                preview(bottomInset: geometry.safeAreaInsets.bottom + 83)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Button {
                            camera.close()
                            dismiss()
                        } label: {
                            cameraIcon("chevron.left")
                        }
                        .accessibilityLabel("Назад")
                        Spacer()
                        if case .recording(let started) = camera.recording {
                            Text(started, style: .timer)
                                .monospacedDigit()
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.65), in: Capsule())
                                .foregroundStyle(.red)
                                .accessibilityLabel("Время записи")
                        } else if camera.preview == .ready, !camera.audioAvailable {
                            Image(systemName: "mic.slash")
                                .padding(8)
                                .background(.black.opacity(0.65), in: Circle())
                                .accessibilityLabel("Запись без звука")
                        }
                        Spacer()
                        Button { showMetrics = true } label: {
                            cameraIcon("slider.horizontal.3")
                        }
                        .accessibilityLabel("Показатели в кадре")
                        .disabled(camera.recording != .idle)
                    }
                    Spacer()
                    ZStack {
                        controls
                        if camera.recording == .idle, let url = camera.latestVideo {
                            HStack {
                                Button { camera.saveToPhotos(url) } label: {
                                    cameraIcon("square.and.arrow.down")
                                }
                                .accessibilityLabel("Сохранить последнее видео в «Фото»")
                                Spacer()
                                ShareLink(item: url) {
                                    cameraIcon("square.and.arrow.up")
                                }
                                .accessibilityLabel("Поделиться последним видео")
                            }
                        }
                    }
                    .frame(height: 68)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .sheet(isPresented: $showMetrics) { metricPicker }
        .alert("WheelLog", isPresented: Binding(
            get: { camera.message != nil },
            set: { if !$0 { camera.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.message ?? "")
        }
    }

    private func cameraIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .semibold))
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.65), in: Circle())
            .contentShape(Circle())
    }

    private func preview(bottomInset: CGFloat) -> some View {
        CameraSurface(session: camera.session,
                      sample: .init(telemetry: wheel.telemetry, demo: wheel.demo, stale: wheel.showingLastReading,
                                    model: wheel.modelName),
                      mask: mask, ready: camera.preview == .ready, bottomInset: bottomInset)
            .overlay {
                switch camera.preview {
                case .ready, .closed:
                    EmptyView()
                case .opening:
                    ProgressView()
                case .unavailable(let reason):
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.title2)
                        Text(reason)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        #if !targetEnvironment(simulator)
                        Button("Настройки iPhone") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.footnote)
                        #endif
                    }
                    .padding(.horizontal, 20)
                }
            }
            .accessibilityLabel("Кадр камеры с телеметрией")
    }

    private var controls: some View {
        Group {
            switch camera.recording {
            case .idle:
                Button {
                    camera.startRecording(mask: mask, demo: wheel.demo)
                } label: {
                    recordIcon(stopping: false)
                }
                .accessibilityLabel("Записать видео")
                .disabled(!camera.canRecord)
                .opacity(camera.canRecord ? 1 : 0.5)
            case .starting, .recording:
                Button { camera.stopRecording() } label: { recordIcon(stopping: true) }
                    .accessibilityLabel("Завершить запись")
            case .saving:
                ProgressView("Сохраняем видео…")
                    .font(.subheadline)
                    .padding(10)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
    }

    private func recordIcon(stopping: Bool) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Circle().strokeBorder(.white, lineWidth: 3)
            RoundedRectangle(cornerRadius: stopping ? 6 : 27)
                .fill(.red)
                .frame(width: stopping ? 27 : 54, height: stopping ? 27 : 54)
        }
        .frame(width: 66, height: 66)
        .contentShape(Circle())
    }

    private var metricPicker: some View {
        NavigationStack {
            Form {
                Label("Скорость", systemImage: "checkmark")
                ForEach(Array(OverlayLayout.available.enumerated()), id: \.element) { index, metric in
                    let bit = 1 << index
                    Toggle(metric.rawValue, isOn: Binding(
                        get: { mask & bit != 0 },
                        set: { included in
                            if included { mask |= bit }
                            else { mask &= ~bit }
                        }
                    ))
                    .tint(RideColors.accent)
                }
            }
            .navigationTitle("Показатели в кадре")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showMetrics = false }
                }
            }
        }
    }
}

@MainActor
struct LibraryView: View {
    @ObservedObject var library: RideLibrary
    @ObservedObject var camera: CameraModel
    let openRoute: () -> Void
    @State private var kind = RideLibrary.Kind.routes
    @State private var selected: RideLibrary.Item?
    @State private var deleting: RideLibrary.Item?
    @State private var deletionFailed = false

    var body: some View {
        RideScreen(title: "Поездки") {
            Picker("Тип записей", selection: $kind) {
                ForEach(RideLibrary.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            if kind == .routes {
                Button(action: openRoute) {
                    Label("Запись маршрута", systemImage: "location")
                }
                .buttonStyle(.borderedProminent)
            }
            let items = library.items.filter { $0.kind == kind }
            if items.isEmpty {
                ContentUnavailableView("Записей пока нет", systemImage: kind.icon)
            }
            ForEach(items) { item in
                RidePanel {
                    HStack(spacing: 10) {
                        Image(systemName: item.kind.icon)
                            .foregroundStyle(RideColors.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                                .font(.subheadline)
                                .foregroundStyle(RideColors.muted)
                        }
                        Spacer()
                        if item.demo {
                            Text("Демо").font(.caption).foregroundStyle(RideColors.muted)
                        }
                        Button(role: .destructive) { deleting = item } label: {
                            Image(systemName: "trash")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Удалить запись")
                    }
                    HStack {
                        if item.kind != .logs {
                            Button { selected = item } label: {
                                Label("Открыть", systemImage: item.kind == .videos ? "play" : "map")
                            }
                        }
                        if item.kind != .routes {
                            ShareLink(item: item.url) {
                                Label("Поделиться", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(item: $selected) { item in
            if item.kind == .videos {
                VideoReview(url: item.url, save: { camera.saveToPhotos(item.url) })
            } else if item.kind == .routes {
                RouteReview(url: item.url)
            }
        }
        .confirmationDialog("Удалить запись из WheelLog?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { item in
            Button("Удалить", role: .destructive) {
                if library.delete(item) { camera.forgetVideo(item.url) }
                else { deletionFailed = true }
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Не удалось удалить запись", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct VideoReview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    let save: () -> Void

    init(url: URL, save: @escaping () -> Void) {
        _player = State(initialValue: AVPlayer(url: url))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle("Видео поездки")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("В «Фото»", action: save) }
                }
        }
        .onDisappear { player.pause() }
    }
}
