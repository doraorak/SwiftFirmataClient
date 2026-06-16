/// Why a ``FirmataClient`` connection ended.
public enum FirmataDisconnectReason: Sendable, Equatable {
    /// ``FirmataClient/disconnect()`` was called locally.
    case localRequest
    /// The device handed the board to another client (latest-wins arbitration).
    /// Detected from the firmware's standard `STRING_DATA` eviction notice, so a
    /// dual-transport board can tell you a different app/computer took over.
    case replacedByAnotherClient
    /// The transport closed or errored (network drop, device reset, power loss…).
    case transportClosed
}

/// Firmata protocol v2.8.0 client.
///
/// All methods are safe to call concurrently; the actor serialises access to
/// the parser, pending continuation map, and outgoing bytes.
///
/// ## One client per connection
/// A `FirmataClient` owns exactly one transport and one connection for its
/// lifetime. To switch transports (Bonjour ↔ BLE) or reconnect, ``disconnect()``
/// this client and create a new one — never point two live clients at the same
/// board, since the firmware enforces a single master and will evict the loser
/// (surfaced as ``FirmataDisconnectReason/replacedByAnotherClient``).
public actor FirmataClient {

    // MARK: - Public stream

    /// Every message received from the device is also published here.
    /// Subscribe from any context; the stream is single-consumer.
    nonisolated public let messages: AsyncStream<FirmataMessage>

    /// Why the connection last ended, or `nil` while connected / never connected.
    /// Read after ``messages`` finishes to find out whether you were evicted.
    public private(set) var lastDisconnectReason: FirmataDisconnectReason?

    /// Sentinel `STRING_DATA` the firmware sends to a client right before evicting
    /// it. Standard Firmata bytes (a 0x01-prefixed string), recognised here.
    public static let evictionNotice = "\u{1}EVICTED"

    // MARK: - Private state

    private let transport: any FirmataTransport
    private var parser = FirmataParser()
    private var readTask: Task<Void, Never>?
    private var pendingDisconnectReason: FirmataDisconnectReason?

    private let messageContinuation: AsyncStream<FirmataMessage>.Continuation

    // One-shot query continuations
    private var pendingVersion:       CheckedContinuation<ProtocolVersion,   Error>?
    private var pendingFirmware:      CheckedContinuation<FirmwareInfo,      Error>?
    private var pendingCapability:    CheckedContinuation<[[PinCapability]], Error>?
    private var pendingAnalogMapping: CheckedContinuation<[UInt8],           Error>?
    private var pendingPinState:      [UInt8:  CheckedContinuation<PinState,  Error>] = [:]
    private var pendingI2C:           [UInt16: [CheckedContinuation<I2CReply, Error>]] = [:]
    private var pendingQueryAllTasks: CheckedContinuation<[UInt8], Error>?
    private var pendingQueryTask:     [UInt8: CheckedContinuation<SchedulerTask?, Error>] = [:]

    // One-shot live reads (Firmata has no synchronous read; we enable reporting
    // and await the next sample). Keyed by a sequence id so a timeout can cancel
    // the exact waiter.
    private var readSeq: UInt64 = 0
    private var pendingDigitalRead: [UInt64: (pin: UInt8,     cont: CheckedContinuation<Bool,   Error>)] = [:]
    private var pendingAnalogRead:  [UInt64: (channel: UInt8, cont: CheckedContinuation<UInt16, Error>)] = [:]

    // Which channels/ports we have reporting enabled for (so a one-shot read can
    // restore the prior state instead of clobbering ongoing reporting).
    private var analogReportingChannels: Set<UInt8> = []
    private var digitalReportingPorts:   Set<UInt8> = []

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
        lastDisconnectReason = nil
        pendingDisconnectReason = nil
        readTask = Task {
            do {
                for try await byte in transport.openStream() {
                    guard let msg = parser.consume(byte) else { continue }
                    // Intercept the eviction sentinel: record the reason and
                    // don't surface it as an ordinary device string.
                    if case .stringData(let s) = msg, s == FirmataClient.evictionNotice {
                        pendingDisconnectReason = .replacedByAnotherClient
                        continue
                    }
                    handleMessage(msg)
                }
                finishDisconnect(reason: pendingDisconnectReason ?? .transportClosed,
                                 error: FirmataError.transportClosed)
            } catch {
                finishDisconnect(reason: pendingDisconnectReason ?? .transportClosed,
                                 error: error)
            }
        }
    }

    /// Stop reading and cancel any in-flight queries.
    public func disconnect() {
        readTask?.cancel()
        readTask = nil
        finishDisconnect(reason: .localRequest, error: FirmataError.transportClosed)
    }

    /// Resolve the connection's end exactly once: record the reason, fail any
    /// in-flight queries, and finish the message stream.
    private func finishDisconnect(reason: FirmataDisconnectReason, error: Error) {
        guard lastDisconnectReason == nil else { return }
        lastDisconnectReason = reason
        cancelAllPending(with: error)
        messageContinuation.finish()
    }

    // MARK: - Incoming message dispatch

    private func handleMessage(_ msg: FirmataMessage) {
        messageContinuation.yield(msg)

        switch msg {
        case .analog(let channel, let value):
            for (id, w) in pendingAnalogRead where w.channel == channel {
                pendingAnalogRead.removeValue(forKey: id)
                w.cont.resume(returning: value)
            }

        case .digital(let port, let mask):
            for (id, w) in pendingDigitalRead where w.pin / 8 == port {
                pendingDigitalRead.removeValue(forKey: id)
                w.cont.resume(returning: (mask >> (w.pin % 8)) & 1 == 1)
            }

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

        case .schedulerTaskList(let ids):
            pop(&pendingQueryAllTasks)?.resume(returning: ids)

        case .schedulerTask(let task):
            pendingQueryTask.removeValue(forKey: task.id)?.resume(returning: task)

        case .schedulerError(let taskId):
            // A query for a non-existent task replies with an error -> nil.
            pendingQueryTask.removeValue(forKey: taskId)?.resume(returning: nil)

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
        pop(&pendingQueryAllTasks)?.resume(throwing: error)
        for cont in pendingQueryTask.values { cont.resume(throwing: error) }
        pendingQueryTask.removeAll()
        for w in pendingDigitalRead.values { w.cont.resume(throwing: error) }
        pendingDigitalRead.removeAll()
        for w in pendingAnalogRead.values { w.cont.resume(throwing: error) }
        pendingAnalogRead.removeAll()
    }

    // MARK: - Digital I/O

    /// Set a pin's operating mode. Do this before reading or writing the pin —
    /// e.g. `.output` before ``digitalWrite(pin:value:)``, `.analog` before
    /// ``analogRead(channel:timeout:)``.
    ///
    /// ```swift
    /// try await client.setPinMode(13, mode: .output)
    /// ```
    ///
    /// - Parameters:
    ///   - pin: The board pin number (GPIO), `0`-based.
    ///   - mode: The role the pin should take — see ``PinMode`` (`.input`,
    ///     `.output`, `.inputPullup`, `.analog`, `.pwm`, `.servo`, `.i2c`, …).
    public func setPinMode(_ pin: UInt8, mode: PinMode) async throws {
        try await transport.send([Cmd.setPinMode, pin, mode.rawValue])
    }

    /// Drive a single pin HIGH or LOW. The pin must already be in `.output` mode.
    ///
    /// - Parameters:
    ///   - pin: The board pin number to drive.
    ///   - value: `true` for HIGH (logic 1), `false` for LOW (logic 0).
    public func digitalWrite(pin: UInt8, value: Bool) async throws {
        try await transport.send([Cmd.setDigitalPinValue, pin, value ? 0x01 : 0x00])
    }

    /// Write all eight pins of a digital port in one message — faster than eight
    /// ``digitalWrite(pin:value:)`` calls. Only pins in `.output` mode are affected.
    ///
    /// - Parameters:
    ///   - port: The 8-pin group: `0` = pins 0-7, `1` = pins 8-15, and so on.
    ///   - pinMask: One bit per pin in the port (bit 0 = first pin). A `1` drives
    ///     that pin HIGH, a `0` drives it LOW.
    public func writeDigitalPort(_ port: UInt8, pinMask: UInt8) async throws {
        let cmd: UInt8 = Cmd.digitalMessage | (port & 0x0F)
        try await transport.send([cmd, pinMask & 0x7F, (pinMask >> 7) & 0x01])
    }

    /// Subscribe (or unsubscribe) to continuous reports for a digital port. While
    /// enabled, the device pushes a ``FirmataMessage/digital(port:pinMask:)`` on the
    /// ``messages`` stream whenever any input pin in the port changes. Use this for
    /// push-style monitoring; for a single value use ``digitalRead(pin:timeout:)``.
    ///
    /// - Parameters:
    ///   - port: The 8-pin group to report (`0` = pins 0-7, …).
    ///   - enable: `true` to start reporting, `false` to stop.
    public func reportDigitalPort(_ port: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportDigitalPort | (port & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
        if enable { digitalReportingPorts.insert(port) } else { digitalReportingPorts.remove(port) }
    }

    /// Read a digital input pin **once** and return its level.
    ///
    /// Firmata has no synchronous read, so this enables port reporting (which makes
    /// the device send the port's current state), awaits the next report, then
    /// restores the prior reporting state. Put the pin in `.input`/`.inputPullup`
    /// first for a meaningful level.
    ///
    /// ```swift
    /// try await client.setPinMode(7, mode: .inputPullup)
    /// let pressed = try await client.digitalRead(pin: 7) == false   // active-low button
    /// ```
    ///
    /// - Parameters:
    ///   - pin: The board pin number to read.
    ///   - timeout: How long to wait for the device's report before giving up.
    ///     Defaults to 2 seconds.
    /// - Returns: `true` for HIGH, `false` for LOW.
    /// - Throws: ``FirmataError/noResponse`` if no report arrives within `timeout`.
    public func digitalRead(pin: UInt8, timeout: Duration = .seconds(2)) async throws -> Bool {
        let port = pin >> 3
        let wasReporting = digitalReportingPorts.contains(port)
        try await reportDigitalPort(port, enable: true)   // forces an immediate resend
        let id = nextReadID()
        do {
            let value: Bool = try await withCheckedThrowingContinuation { cont in
                pendingDigitalRead[id] = (pin, cont)
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutDigitalRead(id)
                }
            }
            if !wasReporting { try? await reportDigitalPort(port, enable: false) }
            return value
        } catch {
            if !wasReporting { try? await reportDigitalPort(port, enable: false) }
            throw error
        }
    }

    // MARK: - Analog I/O

    /// Write an analog (PWM) value to a pin in `.pwm` mode. Pins 0-15 use the
    /// standard analog message; higher pins or values wider than 14 bits fall back
    /// to the extended-analog SysEx automatically.
    ///
    /// - Parameters:
    ///   - pin: The PWM-capable board pin number.
    ///   - value: Duty cycle as an unsigned integer. Its full-scale range is the
    ///     pin's PWM resolution from the capability response (e.g. `0`-`255` for an
    ///     8-bit pin, `0`-`1023` for 10-bit).
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

    /// Subscribe (or unsubscribe) to continuous samples for an analog channel.
    /// While enabled, the device pushes ``FirmataMessage/analog(channel:value:)`` on
    /// the ``messages`` stream every sampling interval. For a single value use
    /// ``analogRead(channel:timeout:)``.
    ///
    /// - Parameters:
    ///   - channel: The analog channel number (A0 = `0`, A1 = `1`, …), per
    ///     ``queryAnalogMapping()``.
    ///   - enable: `true` to start sampling, `false` to stop.
    public func reportAnalogPin(_ channel: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportAnalogPin | (channel & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
        if enable { analogReportingChannels.insert(channel) } else { analogReportingChannels.remove(channel) }
    }

    /// Read an analog input **once** and return the sample.
    ///
    /// Enables reporting for the channel (the pin should be in `.analog` mode),
    /// awaits the next sample (arrives within one sampling interval), then restores
    /// the prior reporting state.
    ///
    /// ```swift
    /// try await client.setPinMode(34, mode: .analog)
    /// let raw = try await client.analogRead(channel: 0)   // 0…1023 / 0…4095 etc.
    /// ```
    ///
    /// - Parameters:
    ///   - channel: The analog channel number (A0 = `0`, …), per ``queryAnalogMapping()``.
    ///   - timeout: How long to wait for a sample before giving up. Default 2 s.
    /// - Returns: The raw ADC value (width depends on the board's ADC resolution).
    /// - Throws: ``FirmataError/noResponse`` if no sample arrives within `timeout`.
    public func analogRead(channel: UInt8, timeout: Duration = .seconds(2)) async throws -> UInt16 {
        let wasReporting = analogReportingChannels.contains(channel)
        try await reportAnalogPin(channel, enable: true)
        let id = nextReadID()
        do {
            let value: UInt16 = try await withCheckedThrowingContinuation { cont in
                pendingAnalogRead[id] = (channel, cont)
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutAnalogRead(id)
                }
            }
            if !wasReporting { try? await reportAnalogPin(channel, enable: false) }
            return value
        } catch {
            if !wasReporting { try? await reportAnalogPin(channel, enable: false) }
            throw error
        }
    }

    // MARK: - One-shot read helpers

    private func nextReadID() -> UInt64 { readSeq &+= 1; return readSeq }

    private func timeoutDigitalRead(_ id: UInt64) {
        pendingDigitalRead.removeValue(forKey: id)?.cont.resume(throwing: FirmataError.noResponse)
    }

    private func timeoutAnalogRead(_ id: UInt64) {
        pendingAnalogRead.removeValue(forKey: id)?.cont.resume(throwing: FirmataError.noResponse)
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

    // MARK: - Scheduler
    //
    // Store tasks (recorded Firmata messages + delays) on the device and let it
    // run them autonomously — even after this client disconnects.

    /// Build a task from a recorded sequence, upload it, and schedule it.
    ///
    /// A *task* is a recording of the same calls you'd normally make live — pin
    /// modes, writes, and ``FirmataTaskRecorder/delay(ms:)`` waits — that the board
    /// stores and replays on its own. It keeps running after this client
    /// disconnects (until overwritten, ``deleteTask(id:)``, ``resetTasks()``, or a
    /// power cycle, since tasks live in RAM).
    ///
    /// The board has no clock you await on, so you don't `await` each step — you
    /// *record* the whole sequence into the `build` closure (synchronously), and a
    /// single `await uploadTask(...)` ships it. From a view, wrap that in a `Task`:
    ///
    /// ```swift
    /// Task {
    ///     // Blink pin 2 every 500 ms — runs on the device, survives disconnect.
    ///     try await client.uploadTask(id: 2, startDelayMs: 0, repeatEveryMs: 500) { t in
    ///         t.setPinMode(2, mode: .output)   // recorded, not sent now
    ///         t.digitalWrite(pin: 2, value: true)
    ///         t.delay(ms: 500)                 // the board waits 500 ms here
    ///         t.digitalWrite(pin: 2, value: false)
    ///     }
    ///     await client.disconnect()            // the LED keeps blinking
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - id: Task id (`0`-`127`). Any existing task with this id is replaced, so
    ///     reusing an id (e.g. the pin number) restarts that task.
    ///   - startDelayMs: Milliseconds to wait before the first run (`0` = immediately).
    ///   - repeatEveryMs: If non-`nil`, the task loops forever, waiting this many
    ///     milliseconds between repetitions (a trailing scheduler delay). `nil` runs
    ///     the sequence once, after which the task is removed.
    ///   - build: A closure that records the actions into the passed-in
    ///     ``FirmataTaskRecorder``. Insert waits with `recorder.delay(ms:)`. The
    ///     calls are captured as bytes — nothing is sent until upload.
    /// - Throws: A transport error, or ``FirmataError/transportClosed`` if the link drops.
    public func uploadTask(
        id: UInt8 = 1,
        startDelayMs: UInt32 = 0,
        repeatEveryMs: UInt32? = nil,
        _ build: (inout FirmataTaskRecorder) -> Void
    ) async throws {
        var recorder = FirmataTaskRecorder()
        build(&recorder)
        if let period = repeatEveryMs { recorder.delay(ms: period) }
        let data = recorder.bytes

        try await deleteTask(id: id)                 // replace any existing task
        try await createTask(id: id, length: data.count)
        let chunkSize = 48
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try await addToTask(id: id, data: Array(data[offset..<end]))
            offset = end
        }
        try await scheduleTask(id: id, delayMs: startDelayMs)

        // Confirm the device has received and stored everything via a round-trip,
        // so it is safe to `disconnect()` immediately after this call returns.
        // (Otherwise tearing down the connection can drop still-buffered writes.)
        _ = try await queryAllTasks()
    }

    /// Create an empty task with `length` bytes reserved.
    public func createTask(id: UInt8, length: Int) async throws {
        try await transport.send([
            Cmd.startSysEx, SysEx.schedulerData, Sched.create, id,
            UInt8(length & 0x7F), UInt8((length >> 7) & 0x7F), Cmd.endSysEx,
        ])
    }

    /// Delete a task by id (no-op on the device if it doesn't exist).
    public func deleteTask(id: UInt8) async throws {
        try await transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.delete, id, Cmd.endSysEx])
    }

    /// Append recorded Firmata bytes to a task. Call after ``createTask(id:length:)``.
    public func addToTask(id: UInt8, data: [UInt8]) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.add, id]
        bytes += encode7BitFirmata(data)
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    /// Schedule a task to start `delayMs` from now (resets its position to 0).
    public func scheduleTask(id: UInt8, delayMs: UInt32) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.schedule, id]
        bytes += encode7BitFirmata(timeBytes(delayMs))
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    /// Delete every scheduler task on the device.
    public func resetTasks() async throws {
        try await transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.reset, Cmd.endSysEx])
    }

    /// Query the ids of all stored tasks.
    public func queryAllTasks() async throws -> [UInt8] {
        return try await withCheckedThrowingContinuation { continuation in
            pendingQueryAllTasks = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.queryAll, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingQueryAllTasks) { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Query a single task; returns `nil` if no task with that id exists.
    public func queryTask(id: UInt8) async throws -> SchedulerTask? {
        return try await withCheckedThrowingContinuation { continuation in
            pendingQueryTask[id] = continuation
            Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.query, id, Cmd.endSysEx])
                } catch {
                    if let c = self.pendingQueryTask.removeValue(forKey: id) { c.resume(throwing: error) }
                }
            }
        }
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
