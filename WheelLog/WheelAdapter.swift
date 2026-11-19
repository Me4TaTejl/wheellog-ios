import CoreBluetooth
import Foundation
import WheelCore

enum WheelFamily: String, CaseIterable, Identifiable {
    case automatic = ""
    case begode
    case extremeBull = "extreme_bull"
    case kingsong
    case inmotion
    case ninebot
    case ninebotZ = "ninebot_z"
    case leaperkim
    case nosfet

    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .begode: "Begode / Gotway"
        case .extremeBull: "Extreme Bull"
        case .kingsong: "KingSong"
        case .inmotion: "InMotion / Solowheel"
        case .ninebot: "Ninebot One / Mini"
        case .ninebotZ: "Ninebot Z"
        case .leaperkim: "LeaperKim / Veteran"
        case .nosfet: "NOSFET"
        }
    }
}

struct WheelAdapter {
    let session: WheelProtocol
    let family: WheelFamily

    static let serialServices = Set([CBUUID(string: "FFE0"), CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")])
    private static let detection = WheelDetection()

    static func hint(_ name: String) -> WheelFamily? {
        detection.hint(name: name).flatMap(WheelFamily.init(rawValue:))
    }

    init?(name: String, services: [CBService], choice: WheelFamily) {
        let topology = services.map { service in
            ([service.uuid] + (service.characteristics ?? []).map(\.uuid))
                .map(\.expandedWheelUUID)
                .joined(separator: ",")
        }
        guard let session = Self.detection.select(name: name, services: topology, forced: choice.rawValue),
              let family = WheelFamily(rawValue: session.family) else { return nil }
        self.session = session
        self.family = family
    }

    var readUUIDs: Set<String> { Set(session.notificationUUIDs) }
    var writeUUID: String { session.writeUUID }

    static func kotlinBytes(_ data: Data) -> KotlinByteArray {
        let result = KotlinByteArray(size: Int32(data.count))
        for (index, byte) in data.enumerated() {
            result.set(index: Int32(index), value: Int8(bitPattern: byte))
        }
        return result
    }

    static func swiftBytes(_ array: KotlinByteArray) -> Data {
        Data((0..<array.size).map { UInt8(bitPattern: array.get(index: $0)) })
    }

    func frame(_ reading: WheelReading) -> WheelFrame {
        let model = reading.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: PedalMode? = switch reading.pedalMode?.intValue {
        case 0: .hard
        case 1: .medium
        case 2: .soft
        default: nil
        }
        return WheelFrame(
            telemetry: Telemetry(speed: reading.speed, pwm: reading.pwm?.doubleValue,
                                 power: reading.power?.doubleValue, voltage: reading.voltage?.doubleValue,
                                 current: reading.current?.doubleValue, phaseCurrent: reading.phaseCurrent?.doubleValue,
                                 battery: reading.battery?.doubleValue, temperature: reading.temperature,
                                 motorTemperature: reading.motorTemperature?.doubleValue,
                                 trip: reading.trip, odometer: reading.odometer?.doubleValue),
            version: reading.version, pedalMode: mode, speedAlarm: nil, tiltBack: nil,
            model: model.isEmpty ? family.title : model
        )
    }
}

extension CBUUID {
    var expandedWheelUUID: String {
        let uuid = uuidString.lowercased()
        return switch uuid.count {
        case 4: "0000\(uuid)-0000-1000-8000-00805f9b34fb"
        case 8: "\(uuid)-0000-1000-8000-00805f9b34fb"
        default: uuid
        }
    }
}
