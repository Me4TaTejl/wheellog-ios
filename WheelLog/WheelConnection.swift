import CoreBluetooth
import Foundation
import SwiftUI

final class WheelConnection: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, scanning, connecting, waiting, live, stale
    }

    struct Device: Identifiable {
        let peripheral: CBPeripheral
        let name: String
        let rssi: Int
        var id: UUID { peripheral.identifier }
        var preferred: Bool {
            let upper = name.uppercased()
            return upper.hasPrefix("LK") || upper.contains("SHERMAN")
        }
    }

    struct SpeedPoint: Identifiable {
        let time: TimeInterval
        let speed: Double
        var id: TimeInterval { time }
    }

    @Published private(set) var state = State.idle
    @Published private(set) var devices = [Device]()
    @Published private(set) var deviceName: String?
    @Published private(set) var frame: ShermanFrame?
    @Published private(set) var telemetry = Telemetry()
    @Published private(set) var speedHistory = [SpeedPoint]()
    @Published private(set) var demo = false
    @Published private(set) var strobe = false
    @Published private(set) var pendingPedalMode: PedalMode?
    @Published private(set) var status = "Подключите Sherman S"
    @Published private(set) var commandStatus: String?

    var onSample: ((Telemetry, Bool, Date) -> Void)?
    var onSourceEnded: (() -> Void)?
    var canControl: Bool {
        state == .live && characteristicHasWrite && pendingDisconnect == nil
    }

    private let serviceID = CBUUID(string: ShermanProtocol.service)
    private let characteristicID = CBUUID(string: ShermanProtocol.characteristic)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var channel: CBCharacteristic?
    private var decoder = ShermanProtocol()
    private var scanRequested = false
    private var lastPacket: TimeInterval?
    private var monitor: Timer?
    private var scanTimeout: DispatchWorkItem?
    private var connectionTimeout: DispatchWorkItem?
    private var demoTimer: Timer?
    private var strobeTimer: Timer?
    private var strobeNextState = false
    private var lightCommanded: Bool?
    private var steadyLight: Bool?
    private var queuedSteadyLight: Bool?
    private var awaitingResponse = false
    private var pendingDisconnect: DispatchWorkItem?
    private var pedalDeadline: TimeInterval?
    private var currentTime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var characteristicHasWrite: Bool {
        guard let channel else { return false }
        return channel.properties.contains(.writeWithoutResponse) || channel.properties.contains(.write)
    }

    func scan() {
        guard peripheral == nil else { return }
        setDemo(false)
        devices.removeAll()
        scanRequested = true
        if let central {
            handleBluetoothState(central)
        } else {
            status = "Запускается Bluetooth…"
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stopScan() {
        scanRequested = false
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        if state == .scanning {
            state = .idle
            status = devices.isEmpty ? "Sherman S не найден" : "Выберите своё колесо"
        }
    }

    func connect(_ device: Device) {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        stopScan()
        setDemo(false)
        decoder = ShermanProtocol()
        commandStatus = nil
        state = .connecting
        status = "Подключение…"
        deviceName = device.name
        peripheral = device.peripheral
        central.connect(device.peripheral)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting || self.state == .waiting else { return }
            self.endConnection(message: "Нет данных Sherman S. Проверьте, что колесо включено и свободно.")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    func disconnect() {
        guard peripheral != nil, pendingDisconnect == nil else { return }
        let wasFlashing = strobe || queuedSteadyLight != nil
        stopStrobe()
        if !wasFlashing {
            endConnection(message: "Колесо отключено")
            return
        }
        let disconnect = DispatchWorkItem { [weak self] in
            self?.endConnection(message: "Колесо отключено")
        }
        pendingDisconnect = disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: disconnect)
    }

    func setDemo(_ enabled: Bool) {
        guard enabled != demo, peripheral == nil else { return }
        onSourceEnded?()
        demoTimer?.invalidate()
        demoTimer = nil
        demo = enabled
        speedHistory.removeAll()
        telemetry = Telemetry()
        if enabled {
            stopScan()
            let start = currentTime
            publish(Telemetry.demo(at: 0))
            demoTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                guard let self, self.demo else { return }
                self.publish(Telemetry.demo(at: self.currentTime - start))
            }
        }
    }

    func setLight(_ on: Bool) {
        guard canControl, !strobe else { return }
        requestSteadyLight(on)
    }

    func startStrobe(hz: Double) {
        guard canControl, !strobe, queuedSteadyLight == nil, [0.5, 1, 2].contains(hz) else { return }
        strobeNextState = !(lightCommanded ?? false)
        strobe = true
        commandStatus = nil
        pulse()
        guard strobe else { return }
        let timer = Timer(timeInterval: 0.5 / hz, repeats: true) { [weak self] _ in
            self?.pulse()
        }
        strobeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopStrobe() {
        guard strobe else { return }
        strobeTimer?.invalidate()
        strobeTimer = nil
        strobe = false
        requestSteadyLight(steadyLight ?? true)
    }

    func setPedals(_ mode: PedalMode) {
        guard canControl, !strobe, pendingPedalMode == nil,
              let frame, let lastPacket, currentTime - lastPacket < 1.5,
              let speed = frame.telemetry.speed, abs(speed) < 1 else { return }
        guard send(ShermanProtocol.pedals(mode)) else {
            commandStatus = "Bluetooth занят. Попробуйте ещё раз."
            return
        }
        pendingPedalMode = mode
        pedalDeadline = currentTime + 2.5
        commandStatus = "Ожидаем подтверждение от колеса…"
    }

    private func requestSteadyLight(_ on: Bool) {
        steadyLight = on
        queuedSteadyLight = on
        flushSteadyLight()
    }

    private func flushSteadyLight() {
        guard let on = queuedSteadyLight else { return }
        guard send(ShermanProtocol.light(on: on)) else { return }
        queuedSteadyLight = nil
        lightCommanded = on
        commandStatus = on ? "Отправлена команда включения фары" : "Отправлена команда выключения фары"
    }

    private func pulse() {
        guard let lastPacket, canControl, currentTime - lastPacket < 2 else {
            stopStrobe()
            return
        }
        guard send(ShermanProtocol.light(on: strobeNextState)) else { return }
        lightCommanded = strobeNextState
        strobeNextState.toggle()
    }

    private func send(_ packet: Data) -> Bool {
        guard let peripheral, peripheral.state == .connected, let channel, channel.isNotifying else { return false }
        if channel.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else { return false }
            peripheral.writeValue(packet, for: channel, type: .withoutResponse)
        } else if channel.properties.contains(.write), !awaitingResponse {
            awaitingResponse = true
            peripheral.writeValue(packet, for: channel, type: .withResponse)
        } else {
            return false
        }
        return true
    }

    private func publish(_ sample: Telemetry) {
        telemetry = sample
        let now = currentTime
        if let speed = Metric.speed.value(in: sample),
           speedHistory.last.map({ now - $0.time >= 0.25 }) ?? true {
            speedHistory.removeAll { now - $0.time > 30 }
            speedHistory.append(.init(time: now, speed: speed))
        }
        onSample?(sample, demo, Date())
    }

    private func checkConnection() {
        let now = currentTime
        if state == .live, let lastPacket, now - lastPacket > 2 {
            state = .stale
            status = "Колесо перестало передавать данные"
            telemetry = Telemetry()
            speedHistory.removeAll()
            stopStrobe()
        }
        if let pedalDeadline, now > pedalDeadline {
            pendingPedalMode = nil
            self.pedalDeadline = nil
            commandStatus = "Колесо не подтвердило режим педалей"
        }
    }

    private func endConnection(message: String) {
        let ending = peripheral
        resetConnection(message: message)
        if let ending { central?.cancelPeripheralConnection(ending) }
    }

    private func resetConnection(message: String) {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        pendingDisconnect?.cancel()
        pendingDisconnect = nil
        monitor?.invalidate()
        monitor = nil
        strobeTimer?.invalidate()
        strobeTimer = nil
        lastPacket = nil
        awaitingResponse = false
        queuedSteadyLight = nil
        steadyLight = nil
        lightCommanded = nil
        strobe = false
        pendingPedalMode = nil
        pedalDeadline = nil
        commandStatus = nil
        peripheral?.delegate = nil
        peripheral = nil
        channel = nil
        deviceName = nil
        frame = nil
        telemetry = Telemetry()
        speedHistory.removeAll()
        onSourceEnded?()
        state = .idle
        status = message
    }

    private func handleBluetoothState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            guard scanRequested, !manager.isScanning else { return }
            state = .scanning
            status = "Поиск колеса…"
            manager.scanForPeripherals(withServices: nil)
            let timeout = DispatchWorkItem { [weak self] in self?.stopScan() }
            scanTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        case .unknown, .resetting:
            if peripheral != nil { resetConnection(message: "Bluetooth перезапускается") }
        default:
            stopScan()
            let message = switch manager.state {
            case .unauthorized: "Разрешите Bluetooth в настройках iPhone"
            case .poweredOff: "Включите Bluetooth на iPhone"
            default: "Bluetooth LE недоступен"
            }
            if peripheral != nil { resetConnection(message: message) }
            else { status = message }
        }
    }
}

extension WheelConnection: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanRequested, (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) != false else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Колесо без имени"
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let upper = name.uppercased()
        guard upper.hasPrefix("LK") || upper.contains("SHERMAN") || upper.contains("VETERAN") ||
              upper.contains("LEAPERKIM") || advertisedServices.contains(serviceID) else { return }
        let device = Device(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { lhs, rhs in
            if lhs.preferred != rhs.preferred { return lhs.preferred }
            return lhs.rssi > rhs.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        state = .waiting
        status = "Ожидаем телеметрию…"
        peripheral.delegate = self
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resetConnection(message: "Не удалось подключиться. Закройте другие приложения для колеса.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resetConnection(message: "Связь с колесом потеряна")
    }
}

extension WheelConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            endConnection(message: "Сервис телеметрии Sherman S недоступен")
            return
        }
        peripheral.discoverCharacteristics([characteristicID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let candidate = service.characteristics?.first(where: { $0.uuid == characteristicID }),
              candidate.properties.contains(.notify) || candidate.properties.contains(.indicate) else {
            endConnection(message: "Колесо не открыло канал телеметрии")
            return
        }
        channel = candidate
        peripheral.setNotifyValue(true, for: candidate)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, characteristic === channel else { return }
        if error != nil || !characteristic.isNotifying {
            endConnection(message: "Не удалось подписаться на телеметрию колеса")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === channel,
              error == nil, let payload = characteristic.value else { return }
        for sample in decoder.receive(payload) {
            lastPacket = currentTime
            if state != .live {
                connectionTimeout?.cancel()
                connectionTimeout = nil
                state = .live
                status = "Телеметрия в реальном времени"
                if monitor == nil {
                    monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        self?.checkConnection()
                    }
                }
            }
            frame = sample
            if let pendingPedalMode, pendingPedalMode == sample.pedalMode {
                self.pendingPedalMode = nil
                pedalDeadline = nil
                commandStatus = "Режим педалей подтверждён"
            }
            publish(sample.telemetry)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral === self.peripheral { flushSteadyLight() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === channel else { return }
        awaitingResponse = false
        if error != nil {
            if strobe { stopStrobe() }
            commandStatus = "Колесо отклонило команду Bluetooth"
        }
        flushSteadyLight()
    }
}
