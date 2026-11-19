import Foundation

struct ShermanFrame {
    let telemetry: Telemetry
    let version: String
    let pedalMode: PedalMode?
    let speedAlarm: Double
    let tiltBack: Double
}

struct ShermanProtocol {
    static let model = "Sherman S"
    static let service = "FFE0"
    static let characteristic = "FFE1"

    private static let header: [UInt8] = [0xDC, 0x5A, 0x5C]
    private var bytes = [UInt8]()
    private var requiresCRC = false

    static func light(on: Bool) -> Data {
        Data((on ? "SetLightON" : "SetLightOFF").utf8)
    }

    static func pedals(_ mode: PedalMode) -> Data {
        let command = switch mode {
        case .soft: "SETs"
        case .medium: "SETm"
        case .hard: "SETh"
        }
        return Data(command.utf8)
    }

    mutating func receive(_ chunk: Data) -> [ShermanFrame] {
        bytes.append(contentsOf: chunk)
        var frames = [ShermanFrame]()
        while !bytes.isEmpty {
            guard bytes.prefix(Self.header.count).elementsEqual(Self.header.prefix(bytes.count)) else {
                bytes.removeFirst()
                continue
            }
            guard bytes.count >= 4 else { break }
            let length = Int(bytes[3])
            guard length == 32 || length == 34 || length >= 38 else {
                bytes.removeFirst()
                continue
            }
            let total = length + 4
            guard bytes.count >= total else { break }
            let packet = Array(bytes.prefix(total))
            let checksum = Self.crc32(packet.prefix(length)) == Self.be32(packet, length)
            guard !(length > 38 || requiresCRC) || checksum,
                  let frame = Self.parse(packet, payloadEnd: checksum ? length : total) else {
                bytes.removeFirst()
                continue
            }
            requiresCRC = requiresCRC || checksum
            bytes.removeFirst(total)
            frames.append(frame)
        }
        return frames
    }

    private static func parse(_ packet: [UInt8], payloadEnd: Int) -> ShermanFrame? {
        let firmware = be16(packet, 28)
        guard firmware / 1000 == 3 else { return nil }

        let voltageRaw = Double(be16(packet, 4))
        let voltage = voltageRaw / 100
        let speed = signed16(packet, 6) / 10
        let phaseCurrent = signed16(packet, 16) / 10
        let temperature = signed16(packet, 18) / 100
        guard (65...110).contains(voltage), abs(speed) <= 150,
              abs(phaseCurrent) <= 400, (-40...150).contains(temperature),
              packet[22] == 0, packet[23] <= 1,
              packet[30] == 0 || packet[30] == 7 else { return nil }

        let mode: PedalMode? = switch be16(packet, 30) {
        case 0: .hard
        case 1: .medium
        case 2: .soft
        default: nil
        }
        let pwmRaw: UInt16? = payloadEnd >= 36 ? be16(packet, 34) : nil
        let pwm = pwmRaw.flatMap { $0 <= 10_000 ? Double($0) / 100 : nil }
        let current = pwm.map { phaseCurrent * $0 / 100 }
        let battery = min(100, max(0, ((voltageRaw - 7935) / 19.5).rounded()))
        let version = String(format: "%03d.%d.%02d", Int(firmware / 1000),
                             Int((firmware % 1000) / 100), Int(firmware % 100))
        return ShermanFrame(
            telemetry: Telemetry(speed: speed, pwm: pwm, power: current.map { $0 * voltage },
                                 voltage: voltage, current: current, phaseCurrent: phaseCurrent,
                                 battery: battery, temperature: temperature,
                                 trip: wordSwappedDistance(packet, 8), odometer: wordSwappedDistance(packet, 12)),
            version: version, pedalMode: mode,
            speedAlarm: Double(be16(packet, 24)) / 10, tiltBack: Double(be16(packet, 26)) / 10
        )
    }

    private static func be16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    private static func signed16(_ bytes: [UInt8], _ index: Int) -> Double {
        Double(Int16(bitPattern: be16(bytes, index)))
    }

    private static func be32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(be16(bytes, index)) << 16 | UInt32(be16(bytes, index + 2))
    }

    private static func wordSwappedDistance(_ bytes: [UInt8], _ index: Int) -> Double {
        let metres = UInt32(be16(bytes, index + 2)) << 16 | UInt32(be16(bytes, index))
        return Double(metres) / 1000
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let bit = crc & 1
                crc >>= 1
                if bit != 0 { crc ^= 0xEDB88320 }
            }
        }
        return ~crc
    }
}
