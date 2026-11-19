import Foundation

enum PedalMode: String, CaseIterable, Identifiable {
    case soft = "Мягкие"
    case medium = "Средние"
    case hard = "Жёсткие"
    var id: Self { self }
}

struct Telemetry: Codable, Equatable {
    var speed: Double? = nil
    var pwm: Double? = nil
    var power: Double? = nil
    var voltage: Double? = nil
    var current: Double? = nil
    var phaseCurrent: Double? = nil
    var battery: Double? = nil
    var temperature: Double? = nil
    var trip: Double? = nil
    var odometer: Double? = nil

    static func demo(at seconds: Double) -> Self {
        let speed = 28 + sin(seconds / 2.9) * 14 + sin(seconds * 1.2) * 2
        let amps = 11 + sin(seconds / 1.53) * 9
        return Self(speed: speed, pwm: 19 + speed * 1.03, power: amps * 121.8,
                    voltage: 121.8, current: amps, phaseCurrent: amps * 2.4,
                    battery: 83, temperature: 37 + sin(seconds / 8) * 2,
                    trip: seconds * 0.008, odometer: 612.4 + seconds * 0.008)
    }
}

struct RideExtrema: Equatable {
    private(set) var speed: Double?
    private(set) var pwm: Double?
    private(set) var current: Double?
    private(set) var power: Double?
    private(set) var temperature: Double?
    private(set) var lowestBattery: Double?

    mutating func include(_ sample: Telemetry) {
        speed = largest(speed, sample.speed.map(abs))
        pwm = largest(pwm, sample.pwm)
        current = largest(current, sample.current)
        power = largest(power, sample.power)
        temperature = largest(temperature, sample.temperature)
        if let battery = sample.battery { lowestBattery = min(lowestBattery ?? battery, battery) }
    }

    private func largest(_ previous: Double?, _ sample: Double?) -> Double? {
        guard let sample else { return previous }
        return max(previous ?? sample, sample)
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case speed = "Скорость"
    case pwm = "ШИМ"
    case power = "Мощность"
    case battery = "Батарея"
    case voltage = "Напряжение"
    case current = "Ток батареи"
    case phaseCurrent = "Фазный ток"
    case temperature = "Температура"
    case trip = "Поездка"
    case odometer = "Пробег"

    var id: Self { self }
    var unit: String {
        switch self {
        case .speed: "км/ч"
        case .pwm, .battery: "%"
        case .power: "Вт"
        case .voltage: "В"
        case .current, .phaseCurrent: "А"
        case .temperature: "°C"
        case .trip, .odometer: "км"
        }
    }

    var key: String {
        switch self {
        case .speed: "speed_kmh"
        case .pwm: "pwm_pct"
        case .power: "estimated_power_w"
        case .battery: "estimated_battery_pct"
        case .voltage: "voltage_v"
        case .current: "estimated_battery_current_a"
        case .phaseCurrent: "phase_current_a"
        case .temperature: "temperature_c"
        case .trip: "trip_km"
        case .odometer: "odometer_km"
        }
    }

    func value(in frame: Telemetry) -> Double? {
        switch self {
        case .speed: frame.speed.map { abs($0) }
        case .pwm: frame.pwm
        case .power: frame.power
        case .voltage: frame.voltage
        case .current: frame.current
        case .phaseCurrent: frame.phaseCurrent
        case .battery: frame.battery
        case .temperature: frame.temperature
        case .trip: frame.trip
        case .odometer: frame.odometer
        }
    }

    func display(_ frame: Telemetry) -> String {
        let precision = switch self {
        case .pwm, .battery, .power: 0
        case .trip: 2
        default: 1
        }
        return value(in: frame)?.formatted(.number.grouping(.never).precision(.fractionLength(precision))) ?? "—"
    }
}
