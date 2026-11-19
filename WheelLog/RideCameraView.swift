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
        NavigationStack {
            ScrollView {
                VStack(spacing: 13) {
                    preview
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity)
                    controls
                    if camera.preview == .ready, !camera.audioAvailable {
                        Label("Запись без звука", systemImage: "mic.slash")
                            .font(.footnote)
                            .foregroundStyle(RideColors.muted)
                    }
                    if let url = camera.latestVideo {
                        HStack {
                            Button { camera.saveToPhotos(url) } label: {
                                Label("В «Фото»", systemImage: "square.and.arrow.down")
                            }
                            ShareLink(item: url) {
                                Label("Поделиться", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 650)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .background(RideColors.background.ignoresSafeArea())
            .navigationTitle("Камера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Назад", systemImage: "chevron.left") {
                        camera.close()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMetrics = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Показатели в кадре")
                    .disabled(camera.recording != .idle)
                }
            }
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
    }

    private var preview: some View {
        CameraSurface(session: camera.session, sample: .init(telemetry: wheel.telemetry, demo: wheel.demo),
                      mask: mask, ready: camera.preview == .ready)
            .aspectRatio(9.0 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 19))
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
                    .offset(y: -28)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 19).strokeBorder(RideColors.line).allowsHitTesting(false)
            }
            .accessibilityLabel("Кадр камеры с телеметрией")
    }

    private var controls: some View {
        HStack(spacing: 11) {
            switch camera.recording {
            case .idle:
                Button {
                    camera.startRecording(mask: mask, demo: wheel.demo)
                } label: {
                    Label("Записать видео", systemImage: "record.circle")
                }
                .disabled(!camera.canRecord)
            case .starting:
                Button { camera.stopRecording() } label: {
                    Label("Остановить", systemImage: "stop.circle.fill")
                }
                ProgressView()
            case .recording(let started):
                Button { camera.stopRecording() } label: {
                    Label("Стоп", systemImage: "stop.circle.fill")
                }
                Text(started, style: .timer)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Время записи")
            case .saving:
                ProgressView("Сохраняем видео…")
                    .font(.subheadline)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
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
    @State private var selected: RideLibrary.Item?

    var body: some View {
        RideScreen(title: "Поездки") {
            if library.items.isEmpty {
                ContentUnavailableView("Записей пока нет", systemImage: "folder",
                                       description: Text("Здесь появятся CSV и видео после завершения записи."))
            }
            ForEach(library.items) { item in
                RidePanel {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isVideo ? "film" : "doc.text")
                            .foregroundStyle(RideColors.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.isVideo ? "Видео MP4" : "Лог CSV").font(.headline)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(RideColors.muted)
                        }
                        Spacer()
                        if item.demo {
                            Text("Демо").font(.caption).foregroundStyle(RideColors.muted)
                        }
                    }
                    HStack {
                        if item.isVideo {
                            Button { selected = item } label: {
                                Label("Смотреть", systemImage: "play")
                            }
                        }
                        ShareLink(item: item.url) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                        Spacer(minLength: 0)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(RideColors.muted)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(item: $selected) { item in
            VideoReview(url: item.url, save: { camera.saveToPhotos(item.url) })
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
