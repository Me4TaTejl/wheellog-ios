import SwiftUI
import UIKit

@main
@MainActor
struct WheelLogApp: App {
    @StateObject private var wheel = WheelConnection()
    @StateObject private var library = RideLibrary()
    @StateObject private var camera = CameraModel()

    var body: some Scene {
        WindowGroup {
            MainTabs(wheel: wheel, library: library, camera: camera)
                .preferredColorScheme(.dark)
        }
    }
}

enum RideColors {
    static let background = Color(red: 0.035, green: 0.052, blue: 0.045)
    static let surface = Color(red: 0.078, green: 0.100, blue: 0.085)
    static let accent = Color(red: 0.84, green: 0.99, blue: 0.38)
    static let muted = Color(red: 0.65, green: 0.71, blue: 0.65)
    static let line = Color.white.opacity(0.10)
}

@MainActor
private struct MainTabs: View {
    enum Page: Hashable { case instruments, camera, wheel, library }

    @ObservedObject var wheel: WheelConnection
    @ObservedObject var library: RideLibrary
    @ObservedObject var camera: CameraModel
    @Environment(\.scenePhase) private var phase
    @State private var page = Page.instruments

    var body: some View {
        TabView(selection: $page) {
            Dashboard(wheel: wheel, library: library) { page = .wheel }
                .tabItem { Label("Приборы", systemImage: "speedometer") }
                .tag(Page.instruments)
            RideCameraView(wheel: wheel, camera: camera)
                .tabItem { Label("Камера", systemImage: "video") }
                .tag(Page.camera)
            WheelControls(wheel: wheel)
                .tabItem { Label("Колесо", systemImage: "lightbulb") }
                .tag(Page.wheel)
            LibraryView(library: library, camera: camera)
                .tabItem { Label("Архив", systemImage: "folder") }
                .tag(Page.library)
        }
        .tint(RideColors.accent)
        .onAppear {
            wheel.onSample = { [weak library] frame, demo, time in
                library?.append(frame, demo: demo, time: time)
            }
            wheel.onSourceEnded = { [weak library] in library?.stopLog() }
            camera.onVideoSaved = { [weak library] in library?.refresh() }
            updateCamera(wheel.telemetry)
            updateIdleTimer()
        }
        .onReceive(wheel.$telemetry) { updateCamera($0) }
        .onChange(of: wheel.strobe) { _, _ in updateIdleTimer() }
        .onChange(of: camera.recording) { _, _ in updateIdleTimer() }
        .onChange(of: page) { _, newPage in
            if newPage == .camera, phase == .active { camera.open() }
            else { camera.close() }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active { wheel.stopStrobe() }
            if newPhase == .background {
                camera.close()
                wheel.stopScan()
            }
            if newPhase == .active, page == .camera {
                camera.open()
            }
            updateIdleTimer()
        }
        .alert("WheelLog", isPresented: Binding(
            get: { camera.message != nil },
            set: { if !$0 { camera.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.message ?? "")
        }
    }

    private func updateCamera(_ frame: Telemetry) {
        camera.update(.init(telemetry: frame, demo: wheel.demo))
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = phase == .active && (camera.recording != .idle || wheel.strobe)
    }
}

struct RideScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

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
        }
    }
}

struct RidePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(RideColors.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(RideColors.line)
                    .allowsHitTesting(false)
            }
    }
}
