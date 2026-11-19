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
        let hint: WheelFamily?
        var id: UUID { peripheral.identifier }
    }

    struct SpeedPoint: Identifiable {
        let time: TimeInterval
        let speed: Double
        let current: Double?
        let pwm: Double?
        var id: TimeInterval { time }
    }

    @Published private(set) var state = State.idle
    @Published private(set) var devices = [Device]()
    @Published private(set) var deviceName: String?
    @Published private(set) var frame: WheelFrame?
    @Published private(set) var modelName = "Моноколесо"
    @Published var preferredFamily = WheelFamily.automatic
    @Published private(set) var telemetry = Telemetry()
    @Published private(set) var extrema = RideExtrema()
    @Published private(set) var speedHistory = [SpeedPoint]()
    @Published private(set) var demo = false
    @Published private(set) var strobe = false
    @Published private(set) var pendingPedalMode: PedalMode?
    @Published private(set) var status = "Подключите моноколесо"
    @Published private(set) var commandStatus: String?

    var onSample: ((Telemetry, Bool, Date) -> Void)?
    var onSourceEnded: (() -> Void)?
    var onTelemetryLost: ((Date) -> Void)?
    var showingLastReading: Bool { !demo && state != .live && telemetry.speed != nil }
    var sourceKey: String {
        if demo { return "demo" }
        if modelName == ShermanProtocol.model { return "sherman_s" }
        if modelName.lowercased().hasPrefix("nosfet") { return "nosfet" }
        if adapter?.isRockwheel == true { return "rockwheel" }
        return adapter?.family.rawValue ?? "wheel"
    }
    var canControlLight: Bool { canWriteSettings && (legacySherman || adapter?.session.hasHeadlight == true) }
    var canStrobe: Bool { canWriteSettings && legacySherman }
    var canControlPedals: Bool {
        // The mode index and readback are known for these protocol families.
        let family = adapter?.family
        return canWriteSettings && (legacySherman ||
            ((family == .leaperkim || family == .kingsong) && adapter?.session.hasPedalModes == true))
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var adapter: WheelAdapter?
    private var connectingFamily = WheelFamily.automatic
    private var pendingServices = Set<CBUUID>()
    private var pendingSubscriptions = Set<String>()
    private var subscribed = Set<String>()
    private var characteristicsByID = [String: CBCharacteristic]()
    private var shermanDecoder = ShermanProtocol()
    private var legacySherman = false
    private var lastTelemetryDevice: UUID?
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
    private var awaitingResponse: CBCharacteristic?
    private var pendingDisconnect: DispatchWorkItem?
    private var pedalDeadline: TimeInterval?
    private var currentTime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var uptimeMillis: Int64 { Int64(currentTime * 1_000) }
    private var canWriteSettings: Bool {
        guard state == .live, pendingDisconnect == nil, let adapter, !adapter.isRockwheel, let lastPacket,
              currentTime - lastPacket < 2, let output = characteristicsByID[adapter.writeUUID] else { return false }
        return output.properties.contains(.writeWithoutResponse) || output.properties.contains(.write)
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
            status = devices.isEmpty ? "Моноколесо не найдено" : "Выберите своё колесо"
        }
    }

    func connect(_ device: Device) {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        stopScan()
        setDemo(false)
        shermanDecoder = ShermanProtocol()
        connectingFamily = preferredFamily
        commandStatus = nil
        state = .connecting
        status = "Подключение…"
        deviceName = device.name
        peripheral = device.peripheral
        central.connect(device.peripheral)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting || self.state == .waiting else { return }
            self.endConnection(message: "Нет телеметрии. Проверьте модель протокола и отключите другие приложения для колеса.")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 24, execute: timeout)
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
        extrema = RideExtrema()
        lastTelemetryDevice = nil
        modelName = enabled ? ShermanProtocol.model : "Моноколесо"
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
        guard canControlLight, !strobe else { return }
        if legacySherman {
            requestSteadyLight(on)
        } else if let adapter, canSubmit(to: adapter.writeUUID),
                  adapter.session.requestLight(enabled: on, now: uptimeMillis) {
            commandStatus = on ? "Отправляем команду включения фары" : "Отправляем команду выключения фары"
            flushProtocolWrites()
        } else {
            commandStatus = "Канал фары занят или недоступен на этой прошивке."
        }
    }

    func resetExtrema() {
        var reset = RideExtrema()
        reset.include(telemetry)
        extrema = reset
    }

    func startStrobe(hz: Double) {
        guard canStrobe, !strobe, queuedSteadyLight == nil, [0.5, 1, 2].contains(hz) else { return }
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
        guard canControlPedals, !strobe, pendingPedalMode == nil,
              let frame, let lastPacket, currentTime - lastPacket < 1.5,
              let speed = frame.telemetry.speed, abs(speed) < 1 else { return }
        let submitted: Bool
        if legacySherman {
            submitted = sendSherman(ShermanProtocol.pedals(mode))
        } else if let adapter, canSubmit(to: adapter.writeUUID) {
            let index: Int32 = switch mode { case .hard: 0; case .medium: 1; case .soft: 2 }
            submitted = adapter.session.requestPedals(mode: index, now: uptimeMillis)
            if submitted { flushProtocolWrites() }
        } else {
            submitted = false
        }
        guard submitted else {
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
        guard sendSherman(ShermanProtocol.light(on: on)) else { return }
        queuedSteadyLight = nil
        lightCommanded = on
        commandStatus = on ? "Отправлена команда включения фары" : "Отправлена команда выключения фары"
    }

    private func pulse() {
        guard canStrobe else {
            stopStrobe()
            return
        }
        guard sendSherman(ShermanProtocol.light(on: strobeNextState)) else { return }
        lightCommanded = strobeNextState
        strobeNextState.toggle()
    }

    private enum WriteResult { case accepted, busy, unavailable }

    private func canSubmit(to uuid: String) -> Bool {
        guard awaitingResponse == nil, let peripheral, let characteristic = characteristicsByID[uuid] else {
            return false
        }
        return !characteristic.properties.contains(.writeWithoutResponse) || peripheral.canSendWriteWithoutResponse
    }

    private func sendSherman(_ packet: Data) -> Bool {
        guard legacySherman, let adapter, subscribed.contains(adapter.writeUUID) else { return false }
        return write(packet, to: adapter.writeUUID, preferred: "AUTO") == .accepted
    }

    private func write(_ packet: Data, to uuid: String, preferred: String) -> WriteResult {
        guard let peripheral, peripheral.state == .connected, let output = characteristicsByID[uuid],
              let type = writeType(for: output, preferred: preferred),
              packet.count <= peripheral.maximumWriteValueLength(for: type) else { return .unavailable }
        guard awaitingResponse == nil else { return .busy }
        if type == .withoutResponse {
            guard peripheral.canSendWriteWithoutResponse else { return .busy }
        } else {
            awaitingResponse = output
        }
        peripheral.writeValue(packet, for: output, type: type)
        return .accepted
    }

    private func writeType(for output: CBCharacteristic, preferred: String) -> CBCharacteristicWriteType? {
        let withResponse = output.properties.contains(.write)
        let withoutResponse = output.properties.contains(.writeWithoutResponse)
        switch preferred {
        case "NO_RESPONSE": return withoutResponse ? .withoutResponse : nil
        case "WITH_RESPONSE": return withResponse ? .withResponse : nil
        default:
            if withoutResponse { return .withoutResponse }
            return withResponse ? .withResponse : nil
        }
    }

    private func flushProtocolWrites() {
        guard !subscribed.isEmpty, let adapter else { return }
        while let next = adapter.session.nextWrite() {
            let payload = WheelAdapter.swiftBytes(next.data)
            let result = write(payload, to: next.characteristic, preferred: next.writeType)
            if result == .busy { return }
            adapter.session.finishWrite(accepted: result == .accepted, now: uptimeMillis)
        }
    }

    private func publish(_ sample: Telemetry) {
        var updated = extrema
        updated.include(sample)
        if updated != extrema { extrema = updated }
        telemetry = sample
        let now = currentTime
        if let speed = Metric.speed.value(in: sample),
           speedHistory.last.map({ now - $0.time >= 0.25 }) ?? true {
            speedHistory.removeAll { now - $0.time > 30 }
            speedHistory.append(.init(time: now, speed: speed, current: sample.current, pwm: sample.pwm))
        }
        onSample?(sample, demo, Date())
    }

    private func checkConnection() {
        adapter?.session.tick(now: uptimeMillis)
        flushProtocolWrites()
        let now = currentTime
        if state == .live, let lastPacket, now - lastPacket > 2 {
            state = .stale
            status = "Колесо перестало передавать данные"
            onTelemetryLost?(Date())
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
        if state == .live { onTelemetryLost?(Date()) }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        pendingDisconnect?.cancel()
        pendingDisconnect = nil
        monitor?.invalidate()
        monitor = nil
        strobeTimer?.invalidate()
        strobeTimer = nil
        lastPacket = nil
        awaitingResponse = nil
        queuedSteadyLight = nil
        steadyLight = nil
        lightCommanded = nil
        strobe = false
        pendingPedalMode = nil
        pedalDeadline = nil
        commandStatus = nil
        peripheral?.delegate = nil
        peripheral = nil
        adapter = nil
        legacySherman = false
        pendingServices.removeAll()
        pendingSubscriptions.removeAll()
        subscribed.removeAll()
        characteristicsByID.removeAll()
        deviceName = nil
        frame = nil
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
        let hint = WheelAdapter.hint(name)
        guard hint != nil || !WheelAdapter.serialServices.isDisjoint(with: advertisedServices)
            || preferredFamily != .automatic else { return }
        let device = Device(peripheral: peripheral, name: name, rssi: RSSI.intValue, hint: hint)
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { lhs, rhs in
            if (lhs.hint != nil) != (rhs.hint != nil) { return lhs.hint != nil }
            return lhs.rssi > rhs.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        state = .waiting
        status = "Ожидаем телеметрию…"
        peripheral.delegate = self
        peripheral.discoverServices(nil)
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
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            endConnection(message: "Сервисы Bluetooth моноколеса недоступны")
            return
        }
        pendingServices = Set(services.map(\.uuid))
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, pendingServices.remove(service.uuid) != nil,
              pendingServices.isEmpty else { return }
        let services = peripheral.services ?? []
        guard let adapter = WheelAdapter(name: deviceName ?? "", services: services, choice: connectingFamily) else {
            let message = connectingFamily == .automatic
                ? "Не удалось определить протокол. Выберите марку в списке «Протокол Bluetooth»."
                : "Выбранный протокол не совпадает с каналами Bluetooth устройства."
            endConnection(message: message)
            return
        }
        self.adapter = adapter
        for characteristic in services.flatMap({ $0.characteristics ?? [] }) {
            characteristicsByID[characteristic.uuid.expandedWheelUUID] = characteristic
        }
        let candidates = adapter.readUUIDs.compactMap { characteristicsByID[$0] }.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        guard !candidates.isEmpty else {
            endConnection(message: "Моноколесо не открыло канал телеметрии")
            return
        }
        pendingSubscriptions = Set(candidates.map { $0.uuid.expandedWheelUUID })
        for candidate in candidates {
            peripheral.setNotifyValue(true, for: candidate)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, let adapter else { return }
        let uuid = characteristic.uuid.expandedWheelUUID
        let initialSubscription = pendingSubscriptions.remove(uuid) != nil
        if initialSubscription && error == nil && characteristic.isNotifying { subscribed.insert(uuid) }
        if error != nil || !characteristic.isNotifying { subscribed.remove(uuid) }
        guard pendingSubscriptions.isEmpty else { return }
        guard !subscribed.isEmpty else {
            endConnection(message: "Не удалось подписаться на телеметрию колеса")
            return
        }
        guard initialSubscription, monitor == nil else { return }
        adapter.session.start(now: uptimeMillis)
        flushProtocolWrites()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkConnection() }
        monitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, let adapter, subscribed.contains(characteristic.uuid.expandedWheelUUID),
              error == nil, let payload = characteristic.value else { return }
        if adapter.family == .leaperkim {
            for sample in shermanDecoder.receive(payload) {
                legacySherman = true
                publish(sample, from: peripheral.identifier)
            }
        }
        adapter.session.receive(bytes: WheelAdapter.kotlinBytes(payload), now: uptimeMillis)
        while let reading = adapter.session.takeReading() {
            if !legacySherman { publish(adapter.frame(reading), from: peripheral.identifier) }
        }
        flushProtocolWrites()
    }

    private func publish(_ sample: WheelFrame, from device: UUID) {
        if lastTelemetryDevice != device {
            extrema = RideExtrema()
            speedHistory.removeAll()
            lastTelemetryDevice = device
        }
        lastPacket = currentTime
        if state != .live {
            connectionTimeout?.cancel()
            connectionTimeout = nil
            state = .live
            status = "Телеметрия в реальном времени"
        }
        if modelName != sample.model { modelName = sample.model }
        frame = sample
        if let pendingPedalMode, pendingPedalMode == sample.pedalMode {
            self.pendingPedalMode = nil
            pedalDeadline = nil
            commandStatus = "Режим педалей подтверждён"
        }
        publish(sample.telemetry)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        flushSteadyLight()
        flushProtocolWrites()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === awaitingResponse else { return }
        awaitingResponse = nil
        if error != nil {
            if strobe { stopStrobe() }
            commandStatus = "Колесо отклонило команду Bluetooth"
        }
        flushSteadyLight()
        flushProtocolWrites()
    }
}
