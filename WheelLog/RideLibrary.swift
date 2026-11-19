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
    struct Item: Identifiable {
        let url: URL
        let date: Date
        let bytes: Int
        var id: URL { url }
        var isVideo: Bool { url.pathExtension == "mp4" }
        var demo: Bool { url.lastPathComponent.hasPrefix("Demo") }
    }

    @Published private(set) var items = [Item]()
    @Published private(set) var logging = false
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var errorMessage: String?

    private var logFile: FileHandle?
    private var logURL: URL?
    private var isDemoLog = false
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

    func refresh() {
        do {
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
            var files = [Item]()
            for (folder, ext) in [("Поездки", "csv"), ("Видео", "mp4")] {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: RideFiles.folder(folder), includingPropertiesForKeys: keys, options: .skipsHiddenFiles
                )
                for url in urls where url.pathExtension == ext && url != logURL {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    files.append(.init(url: url, date: values?.creationDate ?? .distantPast, bytes: values?.fileSize ?? 0))
                }
            }
            items = files.sorted { $0.date > $1.date }
        } catch {
            errorMessage = "Не удалось открыть файлы поездок."
        }
    }

    func startLog(demo: Bool) {
        guard !logging else { return }
        do {
            let folder = try RideFiles.folder("Поездки")
            let url = folder.appending(path: RideFiles.filename(prefix: demo ? "Demo_ride" : "ShermanS", ext: "csv"))
            let header = (["timestamp_utc", "elapsed_s", "source"] + Metric.allCases.map(\.key)).joined(separator: ",") + "\n"
            try Data(header.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            logFile = file
            logURL = url
            isDemoLog = demo
            lastWrite = nil
            startUptime = ProcessInfo.processInfo.systemUptime
            recordingStarted = Date()
            errorMessage = nil
            logging = true
        } catch {
            errorMessage = "Не удалось создать CSV. Проверьте свободное место."
        }
    }

    func append(_ frame: Telemetry, demo: Bool, time: Date) {
        guard let logFile, let startUptime, demo == isDemoLog else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastWrite, now - lastWrite < 0.095 { return }
        lastWrite = now
        let values = Metric.allCases.map { metric in
            metric.value(in: frame).map { format($0) } ?? ""
        }
        let fields = [timestamp.string(from: time), format(now - startUptime), demo ? "demo" : "sherman_s"] + values
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
