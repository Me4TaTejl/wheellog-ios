import CoreLocation
import Foundation
import SwiftUI

struct RouteFix: Codable, Equatable {
    let time: Date
    let latitude: Double
    let longitude: Double
    let speed: Double?
    let altitude: Double?
    let ascent: Double?

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

struct RouteWheelReading: Codable {
    let time: Date
    let telemetry: Telemetry?
}

enum RouteRecord: Codable {
    case start(Date)
    case fix(RouteFix)
    case wheel(RouteWheelReading)
    case end(Date)
}

struct SavedRoute {
    let start: Date
    let end: Date
    let fixes: [RouteFix]
    let wheel: [RouteWheelReading]

    init(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let decoder = JSONDecoder()
        var pending = Data()
        var start: Date?
        var end: Date?
        var fixes = [RouteFix]()
        var readings = [RouteWheelReading]()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            guard let breakPoint = pending.lastIndex(of: 10) else { continue }
            for line in pending[..<breakPoint].split(separator: 10) {
                guard let record = try? decoder.decode(RouteRecord.self, from: Data(line)) else { continue }
                switch record {
                case .start(let time): if start == nil { start = time }
                case .end(let time): end = time
                case .fix(let fix): fixes.append(fix)
                case .wheel(let reading): readings.append(reading)
                }
            }
            pending = Data(pending[pending.index(after: breakPoint)...])
        }
        guard let start else { throw CocoaError(.fileReadCorruptFile) }
        self.start = start
        self.fixes = fixes.sorted { $0.time < $1.time }
        self.wheel = readings.sorted { $0.time < $1.time }
        self.end = max(start, end ?? start, self.fixes.last?.time ?? start, self.wheel.last?.time ?? start)
    }

    func fix(at time: Date) -> RouteFix? {
        latest(fixes, at: time, timestamp: \.time)
    }

    func telemetry(at time: Date) -> Telemetry? {
        guard let reading = latest(wheel, at: time, timestamp: \.time),
              time.timeIntervalSince(reading.time) <= 2 else { return nil }
        return reading.telemetry
    }

    func exportCSV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: RideFiles.filename(prefix: "WheelLog_GPS", ext: "csv")
        )
        let columns = ["timestamp_utc", "elapsed_s", "latitude", "longitude", "gps_speed_kmh",
                       "altitude_m", "elevation_gain_m"] + Metric.allCases.map(\.key)
        try Data((columns.joined(separator: ",") + "\n").utf8).write(to: url, options: .atomic)
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            let times = Set(fixes.map(\.time) + wheel.map(\.time)).sorted()
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var buffer = ""
            for time in times {
                let position = fix(at: time).flatMap { time.timeIntervalSince($0.time) <= 10 ? $0 : nil }
                let values = telemetry(at: time)
                let measurements = [position?.latitude, position?.longitude, position?.speed,
                                    position?.altitude, position?.ascent] + Metric.allCases.map { metric in
                    values.flatMap { metric.value(in: $0) }
                }
                buffer += ([stamp.string(from: time), Self.csvValue(time.timeIntervalSince(start))]
                           + measurements.map(Self.csvValue)).joined(separator: ",") + "\n"
                if buffer.utf8.count > 64_000 {
                    try file.write(contentsOf: Data(buffer.utf8))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try file.write(contentsOf: Data(buffer.utf8))
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func csvValue(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func latest<Value>(_ list: [Value], at date: Date, timestamp: KeyPath<Value, Date>) -> Value? {
        var lower = 0
        var upper = list.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if list[middle][keyPath: timestamp] <= date { lower = middle + 1 }
            else { upper = middle }
        }
        return lower > 0 ? list[lower - 1] : nil
    }
}

final class RouteRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var started: Date?
    @Published private(set) var fixes = [RouteFix]()
    @Published private(set) var waitingForPermission = false
    @Published private(set) var status: String?
    var onFileChange: ((URL?) -> Void)?

    private var manager: CLLocationManager?
    private var file: FileHandle?
    private var ascent = RouteAscent()
    private var lastWheelTime: Date?
    private var encoder = JSONEncoder()

    func start(seed: Telemetry?) {
        guard file == nil, !waitingForPermission else { return }
        status = nil
        let location = manager ?? CLLocationManager()
        manager = location
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            begin(location, seed: seed)
        case .notDetermined:
            waitingForPermission = true
            location.requestWhenInUseAuthorization()
        default:
            status = "Разрешите геопозицию для WheelLog в настройках iPhone."
        }
    }

    func stop() {
        waitingForPermission = false
        guard let file else { return }
        if write(.end(Date())) { finish(file) }
    }

    func append(_ telemetry: Telemetry, at time: Date) {
        guard let started, time >= started else { return }
        if let lastWheelTime, time.timeIntervalSince(lastWheelTime) < 0.095 { return }
        lastWheelTime = time
        _ = write(.wheel(.init(time: time, telemetry: telemetry)))
    }

    func wheelLost(at time: Date) {
        guard file != nil else { return }
        lastWheelTime = nil
        _ = write(.wheel(.init(time: time, telemetry: nil)))
    }

    func fixForLog(at time: Date) -> RouteFix? {
        guard started != nil, let last = fixes.last,
              (0...10).contains(time.timeIntervalSince(last.time)) else { return nil }
        return last
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if waitingForPermission {
                waitingForPermission = false
                begin(manager, seed: nil)
            }
        case .denied, .restricted:
            waitingForPermission = false
            stop()
            status = "Доступ к геопозиции отключён. Разрешите его в настройках iPhone."
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let started else { return }
        if manager.accuracyAuthorization == .reducedAccuracy {
            status = "Для маршрута включите точную геопозицию."
        }
        for location in locations {
            guard CLLocationCoordinate2DIsValid(location.coordinate),
                  (0...65).contains(location.horizontalAccuracy),
                  location.timestamp >= started,
                  fixes.last.map({ location.timestamp > $0.time }) ?? true else { continue }
            let altitude = (0...20).contains(location.verticalAccuracy) && location.altitude.isFinite ? location.altitude : nil
            if let altitude {
                ascent.add(altitude: altitude, accuracy: location.verticalAccuracy, at: location.timestamp)
            }
            let fix = RouteFix(time: location.timestamp,
                               latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                               speed: location.speed >= 0 && location.speed.isFinite ? location.speed * 3.6 : nil,
                               altitude: altitude, ascent: ascent.gain)
            guard write(.fix(fix)) else { return }
            fixes.append(fix)
            status = manager.accuracyAuthorization == .reducedAccuracy ? "Для маршрута включите точную геопозицию." : nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown {
            if started != nil { status = "Ожидаем точный сигнал GPS…" }
        } else if let file {
            finish(file)
            status = "GPS перестал работать. Записанная часть сохранена."
        }
    }

    private func begin(_ manager: CLLocationManager, seed: Telemetry?) {
        do {
            let folder = try RideFiles.folder(RideLibrary.Kind.routes.folder)
            let url = folder.appending(path: RideFiles.filename(prefix: "Ride", ext: "jsonl"))
            let time = Date()
            var header = try encoder.encode(RouteRecord.start(time))
            header.append(10)
            try header.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            file = handle
            fixes.removeAll()
            ascent = RouteAscent()
            lastWheelTime = nil
            started = time
            onFileChange?(url)
            if let seed { append(seed, at: time) }
            guard file != nil else { return }
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            status = "Ожидаем GPS…"
        } catch {
            status = "Не удалось создать файл маршрута."
        }
    }

    @discardableResult
    private func write(_ record: RouteRecord) -> Bool {
        guard let file else { return false }
        do {
            var data = try encoder.encode(record)
            data.append(10)
            try file.write(contentsOf: data)
            return true
        } catch {
            finish(file)
            status = "Запись прервана. Записанная часть сохранена."
            return false
        }
    }

    private func finish(_ handle: FileHandle) {
        manager?.stopUpdatingLocation()
        manager?.allowsBackgroundLocationUpdates = false
        manager?.showsBackgroundLocationIndicator = false
        try? handle.close()
        file = nil
        started = nil
        status = nil
        onFileChange?(nil)
    }
}
