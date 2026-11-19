import Foundation
import SwiftUI

enum RideFiles {
    static func folder(_ name: String) throws -> URL {
        let folder = URL.documentsDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func filename(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = UUID().uuidString.prefix(6)
        return "\(prefix)_\(formatter.string(from: Date()))_\(suffix).\(ext)"
    }
}

final class RideLibrary: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case routes = "Маршруты"
        case logs = "Логи CSV"
        case videos = "Видео"

        var id: Self { self }
        var folder: String { self == .logs ? "Поездки" : rawValue }
        var fileExtension: String {
            switch self {
            case .routes: "jsonl"
            case .logs: "csv"
            case .videos: "mp4"
            }
        }
        var icon: String {
            switch self {
            case .routes: "map"
            case .logs: "doc.text"
            case .videos: "film"
            }
        }
    }

    struct Item: Identifiable {
        let url: URL
        let date: Date
        let bytes: Int
        let kind: Kind
        var id: URL { url }
        var demo: Bool { url.lastPathComponent.hasPrefix("Demo") }
    }

    @Published private(set) var items = [Item]()
    @Published private(set) var logging = false
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var errorMessage: String?

    private var logFile: FileHandle?
    private var logURL: URL?
    private var activeRoute: URL?
    private var logSource = ""
    private var lastWrite: TimeInterval?
    private var startUptime: TimeInterval?
    private let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        refresh()
    }

    func setActiveRoute(_ url: URL?) {
        activeRoute = url
        refresh()
    }

    func refresh() {
        do {
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
            var files = [Item]()
            for kind in Kind.allCases {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: RideFiles.folder(kind.folder), includingPropertiesForKeys: keys, options: .skipsHiddenFiles
                )
                for url in urls where url.pathExtension == kind.fileExtension && url != logURL && url != activeRoute {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    files.append(.init(url: url, date: values?.creationDate ?? .distantPast,
                                       bytes: values?.fileSize ?? 0, kind: kind))
                }
            }
            items = files.sorted { $0.date > $1.date }
        } catch {
            errorMessage = "Не удалось открыть файлы поездок."
        }
    }

    func delete(_ item: Item) -> Bool {
        guard items.contains(where: { $0.id == item.id }), item.url != logURL, item.url != activeRoute else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: item.url)
            errorMessage = nil
            refresh()
            return true
        } catch {
            errorMessage = "Не удалось удалить запись."
            refresh()
            return false
        }
    }

    func startLog(source: String) {
        guard !logging else { return }
        do {
            let folder = try RideFiles.folder(Kind.logs.folder)
            let url = folder.appending(path: RideFiles.filename(prefix: source == "demo" ? "Demo_ride" : source, ext: "csv"))
            let columns = ["timestamp_utc", "elapsed_s", "source"] + Metric.allCases.map(\.key)
                + ["altitude_m", "elevation_gain_m"]
            let header = columns.joined(separator: ",") + "\n"
            try Data(header.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            logFile = file
            logURL = url
            logSource = source
            lastWrite = nil
            startUptime = ProcessInfo.processInfo.systemUptime
            recordingStarted = Date()
            errorMessage = nil
            logging = true
        } catch {
            errorMessage = "Не удалось создать CSV. Проверьте свободное место."
        }
    }

    func append(_ frame: Telemetry, demo: Bool, time: Date, fix: RouteFix?) {
        guard let logFile, let startUptime, demo == (logSource == "demo") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastWrite, now - lastWrite < 0.095 { return }
        lastWrite = now
        let values = Metric.allCases.map { metric in
            metric.value(in: frame).map { format($0) } ?? ""
        }
        let fields = [timestamp.string(from: time), format(now - startUptime), logSource] + values
            + [fix?.altitude.map(format) ?? "", fix?.ascent.map(format) ?? ""]
        do {
            try logFile.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
        } catch {
            stopLog()
            errorMessage = "Запись CSV прервана. Доступные данные сохранены."
        }
    }

    func stopLog() {
        guard let logFile else { return }
        do {
            try logFile.close()
        } catch {
            errorMessage = "Возникла ошибка при закрытии CSV."
        }
        self.logFile = nil
        logURL = nil
        startUptime = nil
        recordingStarted = nil
        logging = false
        refresh()
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
