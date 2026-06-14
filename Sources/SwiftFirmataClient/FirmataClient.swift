/// Firmata protocol v2.8.0 client.
///
/// All methods are safe to call concurrently; the actor serialises access to
/// the parser, pending continuation map, and outgoing bytes.
public actor FirmataClient {

    // MARK: - Public stream

    /// Every message received from the device is also published here.
    /// Subscribe from any context; the stream is single-consumer.
    nonisolated public let messages: AsyncStream<FirmataMessage>

    // MARK: - Private state

    private let transport: any FirmataTransport
    private var parser = FirmataParser()
    private var readTask: Task<Void, Never>?

    private let messageContinuation: AsyncStream<FirmataMessage>.Continuation

    // One-shot query continuations
    private var pendingVersion:       CheckedContinuation<ProtocolVersion,   Error>?
    private var pendingFirmware:      CheckedContinuation<FirmwareInfo,      Error>?
    private var pendingCapability:    CheckedContinuation<[[PinCapability]], Error>?
    private var pendingAnalogMapping: CheckedContinuation<[UInt8],           Error>?
    private var pendingPinState:      [UInt8:  CheckedContinuation<PinState,  Error>] = [:]
    private var pendingI2C:           [UInt16: [CheckedContinuation<I2CReply, Error>]] = [:]

    // MARK: - Init / connect / disconnect

    public init(transport: some FirmataTransport) {
        self.transport = transport
        let (stream, cont) = AsyncStream.makeStream(of: FirmataMessage.self)
        self.messages = stream
        self.messageContinuation = cont
    }

    /// Start the background receive loop. Call once after creating the client.
    public func connect() {
        readTask?.cancel()
        readTask = Task {
            do {
                for try await byte in transport.openStream() {
                    if let msg = parser.consume(byte) {
                        handleMessage(msg)
                    }
                }
            } catch {
                cancelAllPending(with: error)
            }
            messageContinuation.finish()
        }
    }

    /// Stop reading and cancel any in-flight queries.
    public func disconnect() {
        readTask?.cancel()
        readTask = nil
        cancelAllPending(with: FirmataError.transportClosed)
        messageContinuation.finish()
    }

    // MARK: - Incoming message dispatch

    private func handleMessage(_ msg: FirmataMessage) {
        messageContinuation.yield(msg)

        switch msg {
        case .protocolVersion(let v):
            pop(&pendingVersion)?.resume(returning: v)

        case .firmwareReport(let info):
            pop(&pendingFirmware)?.resume(returning: info)

        case .capabilityResponse(let pins):
            pop(&pendingCapability)?.resume(returning: pins)

        case .analogMappingResponse(let mapping):
            pop(&pendingAnalogMapping)?.resume(returning: mapping)

        case .pinStateResponse(let state):
            pendingPinState.removeValue(forKey: state.pin)?.resume(returning: state)

        case .i2cReply(let reply):
            if var queue = pendingI2C[reply.address], !queue.isEmpty {
                let cont = queue.removeFirst()
                pendingI2C[reply.address] = queue.isEmpty ? nil : queue
                cont.resume(returning: reply)
            }

        default:
            break
        }
    }

    private func cancelAllPending(with error: Error) {
        pop(&pendingVersion)?.resume(throwing: error)
        pop(&pendingFirmware)?.resume(throwing: error)
        pop(&pendingCapability)?.resume(throwing: error)
        pop(&pendingAnalogMapping)?.resume(throwing: error)
        for cont in pendingPinState.values { cont.resume(throwing: error) }
        pendingPinState.removeAll()
        for queue in pendingI2C.values { for cont in queue { cont.resume(throwing: error) } }
        pendingI2C.removeAll()
    }

    // MARK: - Digital I/O

    /// Set a pin's operating mode.
    public func setPinMode(_ pin: UInt8, mode: PinMode) async throws {
        try await transport.send([Cmd.setPinMode, pin, mode.rawValue])
    }

    /// Write a digital HIGH/LOW to a single pin (pin must be in `.output` mode).
    public func digitalWrite(pin: UInt8, value: Bool) async throws {
        try await transport.send([Cmd.setDigitalPinValue, pin, value ? 0x01 : 0x00])
    }

    /// Write a bitmask to an entire 8-pin digital port at once.
    /// `port` is 0 for pins 0-7, 1 for pins 8-15, etc.
    public func writeDigitalPort(_ port: UInt8, pinMask: UInt8) async throws {
        let cmd: UInt8 = Cmd.digitalMessage | (port & 0x0F)
        try await transport.send([cmd, pinMask & 0x7F, (pinMask >> 7) & 0x01])
    }

    /// Enable or disable automatic digital-port reports for a port.
    public func reportDigitalPort(_ port: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportDigitalPort | (port & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
    }

    // MARK: - Analog I/O

    /// Write a 14-bit analog value to a PWM-capable pin.
    /// Pins 0-15 use the standard analog message; higher pins or values > 14 bits
    /// fall back to the extended-analog SysEx automatically.
    public func analogWrite(pin: UInt8, value: UInt16) async throws {
        if pin < 16 {
            let cmd: UInt8 = Cmd.analogMessage | (pin & 0x0F)
            try await transport.send([cmd, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)])
        } else {
            try await extendedAnalogWrite(pin: pin, value: Int32(value))
        }
    }

    /// Extended analog write for pins ≥ 16 or values wider than 14 bits (e.g. servo µs).
    public func extendedAnalogWrite(pin: UInt8, value: Int32) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.extendedAnalog, pin]
        encode7Bit(int32: value, into: &bytes)
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    /// Enable or disable automatic analog-pin reports (sampling at the configured interval).
    public func reportAnalogPin(_ channel: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportAnalogPin | (channel & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
    }

    // MARK: - System

    /// Send a system reset; the device will re-initialise.
    public func systemReset() async throws {
        try await transport.send([Cmd.systemReset])
    }

    /// Set the analog sampling interval (default 19 ms on standard firmware).
    public func setSamplingInterval(milliseconds: UInt16) async throws {
        try await transport.send([
            Cmd.startSysEx, SysEx.samplingInterval,
            UInt8(milliseconds & 0x7F), UInt8((milliseconds >> 7) & 0x7F),
            Cmd.endSysEx,
        ])
    }

    /// Send a string to the device (encoded as 14-bit LSB/MSB pairs).
    public func sendString(_ text: String) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.stringData]
        for scalar in text.unicodeScalars {
            bytes.append(UInt8(scalar.value & 0x7F))
            bytes.append(UInt8((scalar.value >> 7) & 0x7F))
        }
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    // MARK: - Queries

    /// Request the protocol version. Returns when the device replies.
    public func queryProtocolVersion() async throws -> ProtocolVersion {
        return try await withCheckedThrowingContinuation { continuation in
            pendingVersion = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.protocolVersion])
                } catch {
                    if let c = self.pop(&self.pendingVersion) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Request the firmware name and version.
    public func queryFirmware() async throws -> FirmwareInfo {
        return try await withCheckedThrowingContinuation { continuation in
            pendingFirmware = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.reportFirmware, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingFirmware) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Request the capability of every pin on the device.
    public func queryCapabilities() async throws -> [[PinCapability]] {
        return try await withCheckedThrowingContinuation { continuation in
            pendingCapability = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.capabilityQuery, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingCapability) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Request the mapping between digital pin numbers and analog channels.
    /// The returned array is indexed by digital pin; value 0x7F means not an analog pin.
    public func queryAnalogMapping() async throws -> [UInt8] {
        return try await withCheckedThrowingContinuation { continuation in
            pendingAnalogMapping = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.analogMappingQuery, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingAnalogMapping) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Request the current mode and value of a pin.
    public func queryPinState(pin: UInt8) async throws -> PinState {
        return try await withCheckedThrowingContinuation { continuation in
            pendingPinState[pin] = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.pinStateQuery, pin, Cmd.endSysEx])
                } catch {
                    if let c = self.pendingPinState.removeValue(forKey: pin) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - I2C

    /// Configure I2C. Call once before any I2C read/write.
    /// `delayMicroseconds` adds a delay between register write and subsequent read.
    public func configureI2C(delayMicroseconds: UInt16 = 0) async throws {
        try await transport.send([
            Cmd.startSysEx, SysEx.i2cConfig,
            UInt8(delayMicroseconds & 0x7F), UInt8((delayMicroseconds >> 7) & 0x7F),
            Cmd.endSysEx,
        ])
    }

    /// Write bytes to an I2C device.
    public func i2cWrite(address: UInt16, data: [UInt8], is10Bit: Bool = false) async throws {
        try await sendI2CRequest(address: address, mode: .write, is10Bit: is10Bit,
                                 autoRestart: false, payload: encode8BitBytes(data))
    }

    /// Read bytes from an I2C device (one-shot). Returns the reply.
    /// If `register` is provided it is written before the read request.
    public func i2cReadOnce(
        address: UInt16,
        register: UInt16? = nil,
        count: UInt16,
        is10Bit: Bool = false
    ) async throws -> I2CReply {
        if let reg = register {
            try await sendI2CRequest(address: address, mode: .write, is10Bit: is10Bit,
                                     autoRestart: true, payload: encode7BitPair(reg))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingI2C[address, default: []].append(continuation)
            Task {
                do {
                    try await self.sendI2CRequest(address: address, mode: .readOnce,
                                                  is10Bit: is10Bit, autoRestart: false,
                                                  payload: self.encode7BitPair(count))
                } catch {
                    if var queue = self.pendingI2C[address], !queue.isEmpty {
                        let cont = queue.removeFirst()
                        self.pendingI2C[address] = queue.isEmpty ? nil : queue
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Start continuous I2C reads. Replies arrive on the ``messages`` stream.
    /// If `register` is provided it is written before starting reads.
    public func i2cStartReading(
        address: UInt16,
        register: UInt16? = nil,
        count: UInt16,
        is10Bit: Bool = false
    ) async throws {
        if let reg = register {
            try await sendI2CRequest(address: address, mode: .write, is10Bit: is10Bit,
                                     autoRestart: true, payload: encode7BitPair(reg))
        }
        try await sendI2CRequest(address: address, mode: .readContinuous,
                                 is10Bit: is10Bit, autoRestart: false,
                                 payload: encode7BitPair(count))
    }

    /// Stop continuous I2C reads for an address.
    public func i2cStopReading(address: UInt16, is10Bit: Bool = false) async throws {
        try await sendI2CRequest(address: address, mode: .stopReading,
                                 is10Bit: is10Bit, autoRestart: false, payload: [])
    }

    // MARK: - Private helpers

    /// Send an I2C_REQUEST. `payload` holds the bytes that follow the control
    /// byte, already in 7-bit form, exactly as they go on the wire:
    ///   • write data  → each 8-bit byte as a 7-bit LSB/MSB pair (``encode8BitBytes``)
    ///   • register / byte-count → a single 14-bit value as a 7-bit pair (``encode7BitPair``)
    /// This mirrors the standard Firmata I2C framing parsed by StandardFirmata
    /// and ConfigurableFirmata.
    private func sendI2CRequest(
        address: UInt16,
        mode: I2CMode,
        is10Bit: Bool,
        autoRestart: Bool,
        payload: [UInt8]
    ) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.i2cRequest]
        bytes.append(UInt8(address & 0x7F))

        // Control byte: bits[4:3]=mode, bit5=10bit, bit6=auto-restart, bits[2:0]=addr MSB
        var control: UInt8 = (mode.rawValue & 0x03) << 3
        if is10Bit {
            control |= 0x20
            control |= UInt8((address >> 7) & 0x07)
        }
        if autoRestart { control |= 0x40 }
        bytes.append(control)

        bytes.append(contentsOf: payload)
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    /// Encode a 14-bit value as a 7-bit LSB/MSB pair.
    private func encode7BitPair(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
    }

    /// Encode raw 8-bit data bytes as consecutive 7-bit LSB/MSB pairs.
    private func encode8BitBytes(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(b & 0x7F)
            out.append((b >> 7) & 0x01)
        }
        return out
    }

    /// Encode a signed 32-bit value as a sequence of 7-bit bytes (little-endian).
    private func encode7Bit(int32 value: Int32, into bytes: inout [UInt8]) {
        var v = value
        repeat {
            bytes.append(UInt8(v & 0x7F))
            v >>= 7
        } while v != 0
    }

    /// Atomically consume an optional continuation.
    private func pop<T>(_ ref: inout CheckedContinuation<T, Error>?) -> CheckedContinuation<T, Error>? {
        defer { ref = nil }
        return ref
    }
}
