#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth

/**
 Connects to a Firmata device over BLE using the Nordic UART Service (NUS).

 Compatible firmware: ConfigurableFirmata with BLEStream (ESP32) or any
 Firmata BLE build that exposes the NUS service/characteristics.

 NUS UUIDs (standard across all BLE serial implementations):
   Service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
   RX char  6E400002-...  (host → device, write-without-response)
   TX char  6E400003-...  (device → host, notify)

 Usage:
 ```swift
 let transport = BLETransport()                        // first NUS device found
 let transport = BLETransport(peripheralName: "Firmata-BLE-ESP32")  // filter by name
 ```

 Add `NSBluetoothAlwaysUsageDescription` to your Info.plist.
 */
public final class BLETransport: NSObject, FirmataTransport, @unchecked Sendable {

    // MARK: - NUS service / characteristic UUIDs

    public static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let rxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let txUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - Private state  (all mutations happen on cbQueue)

    private let cbQueue = DispatchQueue(label: "com.firmata.ble", qos: .utility)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?

    private var streamCont:    AsyncThrowingStream<UInt8, Error>.Continuation?
    private var centralCont:   CheckedContinuation<Void, Error>?
    private var peripheralCont: CheckedContinuation<CBPeripheral, Error>?
    private var discoveryCont: CheckedContinuation<Void, Error>?

    private let nameFilter: String?

    /**
     Connection-readiness gate. `send` must not run before the RX characteristic
     has been discovered; otherwise it would throw `transportClosed` while the
     central is still scanning / discovering. All access on `cbQueue`.
     */
    private var isReady = false
    private var readyError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    public init(peripheralName: String? = nil) {
        self.nameFilter = peripheralName
        super.init()
        central = CBCentralManager(delegate: self, queue: cbQueue)
    }

    // MARK: - FirmataTransport

    public func send(_ bytes: [UInt8]) async throws {
        try await waitUntilReady()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                guard let peripheral = self.peripheral, let rxChar = self.rxChar else {
                    cont.resume(throwing: FirmataError.transportClosed)
                    return
                }
                let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + mtu, bytes.count)
                    peripheral.writeValue(
                        Data(bytes[offset..<end]),
                        for: rxChar,
                        type: .withoutResponse
                    )
                    offset = end
                }
                cont.resume()
            }
        }
    }

    public func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            self.streamCont = continuation
            Task {
                do {
                    try await self.waitForPoweredOn()
                    let p = try await self.scanAndConnect()
                    try await self.discoverNUS(on: p)
                    self.markReady()  // RX characteristic discovered; sends may proceed
                    // stream is live; bytes arrive via didUpdateValue delegate
                } catch {
                    self.markFailed(error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                self.cbQueue.async {
                    if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                }
            }
        }
    }

    // MARK: - Setup steps

    private func waitForPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                if self.central.state == .poweredOn { cont.resume(); return }
                self.centralCont = cont
            }
        }
    }

    private func scanAndConnect() async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CBPeripheral, Error>) in
            cbQueue.async {
                self.peripheralCont = cont
                self.central.scanForPeripherals(withServices: [BLETransport.serviceUUID])
            }
        }
    }

    private func discoverNUS(on peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                self.peripheral = peripheral
                peripheral.delegate = self
                self.discoveryCont = cont
                peripheral.discoverServices([BLETransport.serviceUUID])
            }
        }
    }

    // MARK: - Readiness gate

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async {
                if self.isReady            { cont.resume(); return }
                if let e = self.readyError { cont.resume(throwing: e); return }
                self.readyWaiters.append(cont)
            }
        }
    }

    private func markReady() {
        cbQueue.async {
            guard !self.isReady, self.readyError == nil else { return }
            self.isReady = true
            let waiters = self.readyWaiters; self.readyWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func markFailed(_ error: Error) {
        cbQueue.async {
            guard !self.isReady, self.readyError == nil else { return }
            self.readyError = error
            let waiters = self.readyWaiters; self.readyWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let cont = centralCont; centralCont = nil
            cont?.resume()
        case .poweredOff, .unauthorized, .unsupported, .unknown, .resetting:
            let err = BLETransportError.bluetoothUnavailable(central.state)
            let cont = centralCont; centralCont = nil
            cont?.resume(throwing: err)
            streamCont?.finish(throwing: err)
        @unknown default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if let filter = nameFilter, peripheral.name != filter { return }
        central.stopScan()
        self.peripheral = peripheral   // retain before connect — CBPeripheral is not retained by CoreBluetooth
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let cont = peripheralCont; peripheralCont = nil
        cont?.resume(returning: peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let cont = peripheralCont; peripheralCont = nil
        cont?.resume(throwing: error ?? BLETransportError.connectionFailed)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        streamCont?.finish(throwing: error ?? FirmataError.transportClosed)
        streamCont = nil
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(&discoveryCont, with: error); return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == BLETransport.serviceUUID }) else {
            fail(&discoveryCont, with: BLETransportError.serviceNotFound); return
        }
        peripheral.discoverCharacteristics([BLETransport.rxUUID, BLETransport.txUUID], for: svc)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error { fail(&discoveryCont, with: error); return }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case BLETransport.rxUUID: rxChar = char
            case BLETransport.txUUID: peripheral.setNotifyValue(true, for: char)
            default: break
            }
        }
        let cont = discoveryCont; discoveryCont = nil
        cont?.resume()
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { streamCont?.finish(throwing: error); return }
        characteristic.value?.forEach { streamCont?.yield($0) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { streamCont?.finish(throwing: error) }
    }

    // MARK: - Helpers

    private func fail(_ cont: inout CheckedContinuation<Void, Error>?, with error: Error) {
        let c = cont; cont = nil
        c?.resume(throwing: error)
    }
}

// MARK: - Errors

public enum BLETransportError: Error {
    case bluetoothUnavailable(CBManagerState)
    case connectionFailed
    case serviceNotFound
}

#endif
