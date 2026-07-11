import Foundation
import CryptoKit

/// Why a ``FirmataClient`` connection ended.
public enum FirmataDisconnectReason: Sendable, Equatable {
    /// ``FirmataClient/disconnect()`` was called locally.
    case localRequest
    /**
     The device handed the board to another client (latest-wins arbitration).
     Detected from the firmware's standard `STRING_DATA` eviction notice, so a
     dual-transport board can tell you a different app/computer took over.
     */
    case replacedByAnotherClient
    /// The transport closed or errored (network drop, device reset, power loss…).
    case transportClosed
}

/**
 Firmata protocol v2.8.0 client.

 All methods are safe to call concurrently; the actor serialises access to
 the parser, pending continuation map, and outgoing bytes.

 ## One client per connection
 A `FirmataClient` owns exactly one transport and one connection for its
 lifetime. To switch transports (Bonjour ↔ BLE) or reconnect, ``disconnect()``
 this client and create a new one — never point two live clients at the same
 board, since the firmware enforces a single master and will evict the loser
 (surfaced as ``FirmataDisconnectReason/replacedByAnotherClient``).
 */
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

    // Live internet requests (non-standard extension). Keyed by a sequence id so a
    // timeout cancels the exact waiter; replies are matched oldest-first (FIFO).
    private var httpSeq: UInt64 = 0
    private var pendingHttp: [UInt64: CheckedContinuation<HTTPResponse, Error>] = [:]

    /* One-shot live reads (Firmata has no synchronous read; we enable reporting
       and await the next sample). Keyed by a sequence id so a timeout can cancel
       the exact waiter. */
    private var readSeq: UInt64 = 0
    private var pendingDigitalRead: [UInt64: (pin: UInt8,     cont: CheckedContinuation<Bool,   Error>)] = [:]
    private var pendingAnalogRead:  [UInt64: (channel: UInt8, cont: CheckedContinuation<UInt16, Error>)] = [:]

    // Encrypted Wi-Fi provisioning handshake (non-standard extension).
    private var pendingRegisters:  CheckedContinuation<RegisterSnapshot, Error>?
    private var registersSeq = 0
    private var pendingModules:    CheckedContinuation<[ModuleInfo], Error>?
    private var modulesSeq = 0
    private var pendingWiFiKey:    CheckedContinuation<[UInt8],      Error>?
    private var pendingWiFiStatus: CheckedContinuation<(Int, String), Error>?
    /* Generation counters guarding the two single-slot Wi-Fi continuations above:
       a resolved call's timeout Task keeps sleeping, and without the generation
       check it would wake up and pop a LATER call's pending continuation (seen as
       a spurious `noResponse` at exactly the earlier call's timeout). */
    private var wifiKeySeq    = 0
    private var wifiStatusSeq = 0

    // Which channels/ports we have reporting enabled for (so a one-shot read can
    // restore the prior state instead of clobbering ongoing reporting).
    private var analogReportingChannels: Set<UInt8> = []
    private var digitalReportingPorts:   Set<UInt8> = []

    /* Fire-and-forget timeout tasks for in-flight queries. Tracked so a
       ``disconnect()`` cancels them immediately instead of leaving them to sleep
       until their own deadline. Each removes itself from the registry on completion. */
    private var nextInFlightToken: UInt64 = 0
    private var inFlightTasks: [UInt64: Task<Void, Never>] = [:]

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

        case .registers(let snapshot):
            pop(&pendingRegisters)?.resume(returning: snapshot)

        case .modules(let list):
            pop(&pendingModules)?.resume(returning: list)

        case .httpResponse(let status, let body):
            // Match the oldest in-flight live request (FIFO).
            if let key = pendingHttp.keys.min() {
                pendingHttp.removeValue(forKey: key)?
                    .resume(returning: HTTPResponse(status: status, body: body))
            }

        case .unknownSysEx(let id, let data) where id == WiFiCfg.command:
            handleWiFiConfigReply(data)

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
        pop(&pendingRegisters)?.resume(throwing: error)
        pop(&pendingModules)?.resume(throwing: error)
        pop(&pendingQueryAllTasks)?.resume(throwing: error)
        for cont in pendingQueryTask.values { cont.resume(throwing: error) }
        pendingQueryTask.removeAll()
        for w in pendingDigitalRead.values { w.cont.resume(throwing: error) }
        pendingDigitalRead.removeAll()
        for w in pendingAnalogRead.values { w.cont.resume(throwing: error) }
        pendingAnalogRead.removeAll()
        for cont in pendingHttp.values { cont.resume(throwing: error) }
        pendingHttp.removeAll()
        pop(&pendingWiFiKey)?.resume(throwing: error)
        pop(&pendingWiFiStatus)?.resume(throwing: error)
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
    }

    /// Allocate a tracking token for a fire-and-forget timeout task.
    private func nextTrackingToken() -> UInt64 {
        defer { nextInFlightToken &+= 1 }
        return nextInFlightToken
    }
    /// Remove a finished timeout task from the registry.
    private func clearInFlight(_ token: UInt64) { inFlightTasks[token] = nil }

    // MARK: - Digital I/O

    /**
     Set a pin's operating mode. Do this before reading or writing the pin —
     e.g. `.output` before ``digitalWrite(pin:high:)``, `.analog` before
     ``analogRead(channel:timeout:)``.

     ```swift
     try await client.setPinMode(13, mode: .output)
     ```

     - Parameters:
       - pin: The board pin number (GPIO), `0`-based.
       - mode: The role the pin should take — see ``PinMode`` (`.input`,
         `.output`, `.inputPullup`, `.analog`, `.pwm`, `.servo`, `.i2c`, …).
     */
    private func setPinMode(_ pin: UInt8, mode: PinMode) async throws {
        try await transport.send([Cmd.setPinMode, pin, mode.rawValue])
    }

    /**
     Drive a single pin HIGH or LOW. The pin must already be in `.output` mode.

     - Parameters:
       - pin: The board pin number to drive.
       - high: `true` for HIGH (logic 1), `false` for LOW (logic 0).
     */
    private func digitalWrite(pin: UInt8, high: Bool) async throws {
        try await transport.send([Cmd.setDigitalPinValue, pin, high ? 0x01 : 0x00])
    }

    /**
     Write all eight pins of a digital port in one message — faster than eight
     ``digitalWrite(pin:high:)`` calls. Only pins in `.output` mode are affected.

     - Parameters:
       - port: The 8-pin group: `0` = pins 0-7, `1` = pins 8-15, and so on.
       - pinMask: One bit per pin in the port (bit 0 = first pin). A `1` drives
         that pin HIGH, a `0` drives it LOW.
     */
    public func writeDigitalPort(_ port: UInt8, pinMask: UInt8) async throws {
        let cmd: UInt8 = Cmd.digitalMessage | (port & 0x0F)
        try await transport.send([cmd, pinMask & 0x7F, (pinMask >> 7) & 0x01])
    }

    /**
     Subscribe (or unsubscribe) to continuous reports for a digital port. While
     enabled, the device pushes a ``FirmataMessage/digital(port:pinMask:)`` on the
     ``messages`` stream whenever any input pin in the port changes. Use this for
     push-style monitoring; for a single value use ``digitalRead(pin:timeout:)``.

     - Parameters:
       - port: The 8-pin group to report (`0` = pins 0-7, …).
       - enable: `true` to start reporting, `false` to stop.
     */
    public func reportDigitalPort(_ port: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportDigitalPort | (port & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
        if enable { digitalReportingPorts.insert(port) } else { digitalReportingPorts.remove(port) }
    }

    /**
     Read a digital input pin **once** and return its level.

     Firmata has no synchronous read, so this enables port reporting (which makes
     the device send the port's current state), awaits the next report, then
     restores the prior reporting state. Put the pin in `.input`/`.inputPullup`
     first for a meaningful level.

     ```swift
     try await client.setPinMode(7, mode: .inputPullup)
     let pressed = try await client.digitalRead(pin: 7) == false   // active-low button
     ```

     - Parameters:
       - pin: The board pin number to read.
       - timeout: How long to wait for the device's report before giving up.
         Defaults to 2 seconds.
     - Returns: `true` for HIGH, `false` for LOW.
     - Throws: ``FirmataError/noResponse`` if no report arrives within `timeout`.
     */
    private func digitalRead(pin: UInt8, timeout: Duration = .seconds(2)) async throws -> Bool {
        let port = pin >> 3
        let wasReporting = digitalReportingPorts.contains(port)
        try await reportDigitalPort(port, enable: true)   // forces an immediate resend
        let id = nextReadID()
        do {
            let value: Bool = try await withCheckedThrowingContinuation { cont in
                pendingDigitalRead[id] = (pin, cont)
                let token = nextTrackingToken()
                inFlightTasks[token] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutDigitalRead(id)
                    await self?.clearInFlight(token)
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

    /**
     Write an analog (PWM) value to a channel in `.pwm` mode. Channels 0-15 use
     the standard analog message; higher channels or values wider than 14 bits
     fall back to the extended-analog SysEx automatically.

     - Note: For Firmata PWM the "channel" is the pin's analog-message channel,
       which for pins 0-15 is the pin number itself.
     - Parameters:
       - channel: The PWM channel (pin number for 0-15).
       - value: Duty cycle as an unsigned integer. Its full-scale range is the
         pin's PWM resolution from the capability response (e.g. `0`-`255` for an
         8-bit pin, `0`-`1023` for 10-bit).
     */
    private func analogWrite(channel: UInt8, value: UInt16) async throws {
        if channel < 16 {
            let cmd: UInt8 = Cmd.analogMessage | (channel & 0x0F)
            try await transport.send([cmd, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)])
        } else {
            try await extendedAnalogWrite(pin: channel, value: Int32(value))
        }
    }

    /// Extended analog write for pins ≥ 16 or values wider than 14 bits (e.g. servo µs).
    private func extendedAnalogWrite(pin: UInt8, value: Int32) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.extendedAnalog, pin]
        encode7Bit(int32: value, into: &bytes)
        bytes.append(Cmd.endSysEx)
        try await transport.send(bytes)
    }

    /**
     Subscribe (or unsubscribe) to continuous samples for an analog channel.
     While enabled, the device pushes ``FirmataMessage/analog(channel:value:)`` on
     the ``messages`` stream every sampling interval. For a single value use
     ``analogRead(channel:timeout:)``.

     - Parameters:
       - channel: The analog channel number (A0 = `0`, A1 = `1`, …), per
         ``queryAnalogMapping()``.
       - enable: `true` to start sampling, `false` to stop.
     */
    private func reportAnalogChannel(_ channel: UInt8, enable: Bool) async throws {
        let cmd: UInt8 = Cmd.reportAnalogChannel | (channel & 0x0F)
        try await transport.send([cmd, enable ? 0x01 : 0x00])
        if enable { analogReportingChannels.insert(channel) } else { analogReportingChannels.remove(channel) }
    }

    /**
     Read an analog input **once** and return the sample.

     Enables reporting for the channel (the pin should be in `.analog` mode),
     awaits the next sample (arrives within one sampling interval), then restores
     the prior reporting state.

     ```swift
     try await client.setPinMode(34, mode: .analog)
     let raw = try await client.analogRead(channel: 0)   // 0…1023 / 0…4095 etc.
     ```

     - Parameters:
       - channel: The analog channel number (A0 = `0`, …), per ``queryAnalogMapping()``.
       - timeout: How long to wait for a sample before giving up. Default 2 s.
     - Returns: The raw ADC value (width depends on the board's ADC resolution).
     - Throws: ``FirmataError/noResponse`` if no sample arrives within `timeout`.
     */
    private func analogRead(channel: UInt8, timeout: Duration = .seconds(2)) async throws -> UInt16 {
        let wasReporting = analogReportingChannels.contains(channel)
        try await reportAnalogChannel(channel, enable: true)
        let id = nextReadID()
        do {
            let value: UInt16 = try await withCheckedThrowingContinuation { cont in
                pendingAnalogRead[id] = (channel, cont)
                let token = nextTrackingToken()
                inFlightTasks[token] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutAnalogRead(id)
                    await self?.clearInFlight(token)
                }
            }
            if !wasReporting { try? await reportAnalogChannel(channel, enable: false) }
            return value
        } catch {
            if !wasReporting { try? await reportAnalogChannel(channel, enable: false) }
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
    public func setSamplingInterval(_ interval: Duration) async throws {
        let ms = UInt16(clamping: interval.firmataMilliseconds)
        try await transport.send([
            Cmd.startSysEx, SysEx.samplingInterval,
            UInt8(ms & 0x7F), UInt8((ms >> 7) & 0x7F),
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

    /* MARK: - Internet actions (non-standard extension)
       Ask the device to make an HTTP(S) request over *its* Wi-Fi and return the
       result here. Same op the scheduler uses, sent live: the firmware blocks
       briefly while it performs the request, then replies with status + body.
       (For requests that keep running after you disconnect, record
       ``FirmataTaskRecorder/httpGet(_:statusInto:)`` into a task instead.) */

    /**
     Have the device perform an HTTP(S) `GET` and return the result. Inspect the
     body on the host with ``HTTPResponse/json()`` / ``HTTPResponse/decode(_:)``.
     - Parameters:
       - url: The `http://`/`https://` URL (ASCII). `https://` certs are validated
         on-device against the bundled root CAs.
       - timeout: How long to wait for the device's reply before giving up.
     - Throws: ``FirmataError/noResponse`` on timeout, or a transport error.
     */
    public func httpGet(_ url: String, timeout: Duration = .seconds(15)) async throws -> HTTPResponse {
        try await sendHttpAndAwait(
            httpOpBytes(method: 0, statusReg: .reg(15), url: url, body: nil), timeout: timeout)
    }

    /**
     Have the device perform an HTTP(S) `POST` (`Content-Type: application/json`)
     and return the result.
     - Parameters:
       - url: The `http://`/`https://` URL (ASCII; `https://` certs are validated on-device).
       - body: The request body (e.g. JSON). ASCII.
       - timeout: How long to wait for the device's reply before giving up.
     - Throws: ``FirmataError/noResponse`` on timeout, or a transport error.
     */
    public func httpPost(_ url: String, body: String, timeout: Duration = .seconds(15)) async throws -> HTTPResponse {
        try await sendHttpAndAwait(
            httpOpBytes(method: 1, statusReg: .reg(15), url: url, body: body), timeout: timeout)
    }

    private func sendHttpAndAwait(_ bytes: [UInt8], timeout: Duration) async throws -> HTTPResponse {
        let id = httpSeq; httpSeq &+= 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingHttp[id] = continuation
            let token = nextTrackingToken()
            inFlightTasks[token] = Task {
                do {
                    try await self.transport.send(bytes)
                } catch {
                    if let c = self.pendingHttp.removeValue(forKey: id) { c.resume(throwing: error) }
                    self.clearInFlight(token)
                    return
                }
                try? await Task.sleep(for: timeout)
                if let c = self.pendingHttp.removeValue(forKey: id) {
                    c.resume(throwing: FirmataError.noResponse)
                }
                self.clearInFlight(token)
            }
        }
    }

    /* MARK: - Wi-Fi provisioning (encrypted, non-standard extension)
       Hand the board its Wi-Fi credentials over whatever transport is connected
       (typically BLE, before Wi-Fi is up). An ephemeral X25519 ECDH handshake
       derives an AES-256-GCM key (HKDF-SHA256), so the password is never sent in
       the clear — a passive sniffer sees only public keys + ciphertext. Creds are
       saved on the device (NVS) and override the compile-time defaults at boot. */

    /**
     Securely set the device's Wi-Fi credentials and have it (re)connect.
     - Returns: the resulting ``WiFiStatus`` (connected + IP).
     - Throws: ``FirmataError/wifiCredentialsRejected`` if the encrypted handshake
       failed to authenticate (wrong key / tampered frame), or
       ``FirmataError/noResponse`` on timeout.
     */
    @discardableResult
    public func provisionWiFi(ssid: String, password: String,
                              timeout: Duration = .seconds(25)) async throws -> WiFiStatus {
        let devPub = try await wifiBeginHandshake(timeout: timeout)        // device ephemeral pubkey
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let shared = try priv.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(devPub)))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                    salt: Data(WiFiCfg.hkdfSalt.utf8), sharedInfo: Data(), outputByteCount: 32)
        let s = Array(ssid.utf8), p = Array(password.utf8)
        guard s.count <= 127, p.count <= 127 else { throw FirmataError.invalidData }
        var pt = Data([UInt8(s.count)]); pt.append(contentsOf: s)
        pt.append(UInt8(p.count));       pt.append(contentsOf: p)
        let sealed = try AES.GCM.seal(pt, using: key)
        let payload = [UInt8](priv.publicKey.rawRepresentation)
                    + [UInt8](sealed.nonce) + [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
        let (code, ip) = try await sendWiFiAndAwaitStatus(wifiFrame(WiFiCfg.set, payload), timeout: timeout)
        if code == 2 { throw FirmataError.wifiCredentialsRejected }
        return WiFiStatus(connected: code == 1, ip: code == 1 ? ip : nil)
    }

    /// Ask the device whether it's currently joined to Wi-Fi (and its IP).
    public func queryWiFiStatus(timeout: Duration = .seconds(5)) async throws -> WiFiStatus {
        let (code, ip) = try await sendWiFiAndAwaitStatus(wifiFrame(WiFiCfg.query), timeout: timeout)
        return WiFiStatus(connected: code == 1, ip: code == 1 ? ip : nil)
    }

    /// Clear any stored (provisioned) credentials; the device falls back to its
    /// compile-time defaults on the next boot.
    public func forgetWiFi(timeout: Duration = .seconds(5)) async throws {
        _ = try await sendWiFiAndAwaitStatus(wifiFrame(WiFiCfg.forget), timeout: timeout)
    }

    private func wifiFrame(_ sub: UInt8, _ body: [UInt8] = []) -> [UInt8] {
        [Cmd.startSysEx, WiFiCfg.command, sub] + encodeWiFiPairs(body) + [Cmd.endSysEx]
    }
    private func encodeWiFiPairs(_ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](); o.reserveCapacity(b.count * 2)
        for x in b { o.append(x & 0x7F); o.append((x >> 7) & 0x01) }
        return o
    }
    private func decodeWiFiPairs(_ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](); var i = 0
        while i + 1 < b.count { o.append((b[i] & 0x7F) | ((b[i + 1] & 0x01) << 7)); i += 2 }
        return o
    }
    private func wifiBeginHandshake(timeout: Duration) async throws -> [UInt8] {
        wifiKeySeq &+= 1
        let seq = wifiKeySeq
        return try await withCheckedThrowingContinuation { cont in
            pendingWiFiKey = cont
            let token = nextTrackingToken()
            inFlightTasks[token] = Task {
                do { try await self.transport.send(self.wifiFrame(WiFiCfg.begin)) }
                catch { if let c = self.pop(&self.pendingWiFiKey) { c.resume(throwing: error) }; self.clearInFlight(token); return }
                try? await Task.sleep(for: timeout)
                if seq == self.wifiKeySeq, let c = self.pop(&self.pendingWiFiKey) {
                    c.resume(throwing: FirmataError.noResponse)
                }
                self.clearInFlight(token)
            }
        }
    }
    private func sendWiFiAndAwaitStatus(_ frame: [UInt8], timeout: Duration) async throws -> (Int, String) {
        wifiStatusSeq &+= 1
        let seq = wifiStatusSeq
        return try await withCheckedThrowingContinuation { cont in
            pendingWiFiStatus = cont
            let token = nextTrackingToken()
            inFlightTasks[token] = Task {
                do { try await self.transport.send(frame) }
                catch { if let c = self.pop(&self.pendingWiFiStatus) { c.resume(throwing: error) }; self.clearInFlight(token); return }
                try? await Task.sleep(for: timeout)
                if seq == self.wifiStatusSeq, let c = self.pop(&self.pendingWiFiStatus) {
                    c.resume(throwing: FirmataError.noResponse)
                }
                self.clearInFlight(token)
            }
        }
    }
    private func handleWiFiConfigReply(_ data: [UInt8]) {
        guard let sub = data.first else { return }
        switch sub {
        case WiFiCfg.key:
            pop(&pendingWiFiKey)?.resume(returning: decodeWiFiPairs(Array(data.dropFirst())))
        case WiFiCfg.status:
            guard data.count >= 3 else { return }
            let code = Int(data[1]); let ipLen = Int(data[2])
            let ipBytes = decodeWiFiPairs(Array(data.dropFirst(3)))
            let ip = String(decoding: ipBytes.prefix(ipLen), as: UTF8.self)
            pop(&pendingWiFiStatus)?.resume(returning: (code, ip))
        default: break
        }
    }

    // MARK: - Modules (optional firmware features, 2.9+)

    /* Modules are compile-time firmware plugins behind one reserved SysEx: discover
       them at runtime, then talk to one by id. Typed wrappers (like ``ir``) sit on
       top of these two generic calls. */

    /// List the modules this firmware was built with (empty on older firmwares —
    /// which never reply, so this times out; treat a timeout as "no module support").
    public func queryModules(timeout: Duration = .seconds(2)) async throws -> [ModuleInfo] {
        modulesSeq &+= 1
        let seq = modulesSeq
        return try await withCheckedThrowingContinuation { cont in
            pendingModules = cont
            let token = nextTrackingToken()
            inFlightTasks[token] = Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.moduleData, Module.query, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingModules) { c.resume(throwing: error) }
                    self.clearInFlight(token); return
                }
                try? await Task.sleep(for: timeout)
                if seq == self.modulesSeq, let c = self.pop(&self.pendingModules) {
                    c.resume(throwing: FirmataError.noResponse)
                }
                self.clearInFlight(token)
            }
        }
    }

    /// Send a raw payload to module `id` (its own protocol; bytes must be 7-bit).
    /// Module events come back on ``messages`` as ``FirmataMessage/moduleEvent(id:payload:)``.
    public func sendToModule(id: UInt8, payload: [UInt8]) async throws {
        guard (0x01...0x7E).contains(id) else { throw FirmataError.invalidData }
        try await transport.send([Cmd.startSysEx, SysEx.moduleData, id]
                                 + payload.map { $0 & 0x7F } + [Cmd.endSysEx])
    }

    // MARK: - Registers & servo (firmware 2.8+)

    /* Registers are the shared state of the task extension: 16 Int32 cells R0-R15
       and 8 floats F0-F7, global across all tasks AND this live session. These
       calls read/write them from the host, so a task can react to host-set values
       (and vice versa) without re-uploading anything. */

    /// Write `R[index] = value` (`index` 0…15) — visible to every task immediately.
    public func setRegister(_ index: UInt8, to value: Int32) async throws {
        guard index <= 15 else { throw FirmataError.invalidData }
        try await transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand,
                                  Sched.extSet, index & 0x0F]
                                 + limbs5(UInt32(bitPattern: value)) + [Cmd.endSysEx])
    }

    /// Write `F[index] = value` (`index` 0…7).
    public func setFloatRegister(_ index: UInt8, to value: Float) async throws {
        guard index <= 7 else { throw FirmataError.invalidData }
        try await transport.send([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand,
                                  Sched.extSetFloat, index & 0x07]
                                 + limbs5(value.bitPattern) + [Cmd.endSysEx])
    }

    /// Snapshot all registers (`R0…R15` + `F0…F7`) as the device holds them right now.
    /// - Throws: ``FirmataError/noResponse`` on timeout.
    public func queryRegisters(timeout: Duration = .seconds(2)) async throws -> RegisterSnapshot {
        registersSeq &+= 1
        let seq = registersSeq
        return try await withCheckedThrowingContinuation { cont in
            pendingRegisters = cont
            let token = nextTrackingToken()
            inFlightTasks[token] = Task {
                do {
                    try await self.transport.send([Cmd.startSysEx, SysEx.schedulerData,
                                                   Sched.extCommand, Sched.extRegQuery, Cmd.endSysEx])
                } catch {
                    if let c = self.pop(&self.pendingRegisters) { c.resume(throwing: error) }
                    self.clearInFlight(token); return
                }
                try? await Task.sleep(for: timeout)
                if seq == self.registersSeq, let c = self.pop(&self.pendingRegisters) {
                    c.resume(throwing: FirmataError.noResponse)
                }
                self.clearInFlight(token)
            }
        }
    }

    /// Configure a pin as a servo output with a pulse range (standard `SERVO_CONFIG`).
    /// `setPinMode(pin, mode: .servo)` is the shorthand for the 544–2400 µs default.
    private func configureServo(pin: UInt8,
                               minPulseMicros: UInt16 = 544,
                               maxPulseMicros: UInt16 = 2400) async throws {
        try await transport.send([Cmd.startSysEx, SysEx.servoConfig, pin & 0x7F,
                                  UInt8(minPulseMicros & 0x7F), UInt8((minPulseMicros >> 7) & 0x7F),
                                  UInt8(maxPulseMicros & 0x7F), UInt8((maxPulseMicros >> 7) & 0x7F),
                                  Cmd.endSysEx])
    }

    /// Set a PWM pin's LEDC frequency (Hz, up to 2 MHz) and duty resolution (1–14 bits)
    /// — `PWM_CONFIG`. `setPinMode(pin, mode: .pwm)` keeps the firmware default; use
    /// this for motors (20 kHz+) or a passive buzzer (the frequency *is* the tone).
    private func configurePWM(pin: UInt8, frequencyHz: UInt32, resolutionBits: UInt8) async throws {
        let f = min(frequencyHz, 0x1F_FFFF)                       // 3 × 7-bit little-endian
        try await transport.send([Cmd.startSysEx, SysEx.pwmConfig, pin & 0x7F,
                                  UInt8(f & 0x7F), UInt8((f >> 7) & 0x7F), UInt8((f >> 14) & 0x7F),
                                  min(max(resolutionBits, 1), 14),
                                  Cmd.endSysEx])
    }

    /// Drive a servo pin: `0…180` is an angle in degrees; `≥ 544` is a raw pulse
    /// width in µs (standard Firmata dual meaning). Routes through the analog
    /// message for pins ≤ 15 and extended analog above.
    private func servoWrite(pin: UInt8, value: Int32) async throws {
        if pin <= 15 {
            let v = UInt16(clamping: value)
            try await transport.send([Cmd.analogMessage | (pin & 0x0F),
                                      UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)])
        } else {
            try await extendedAnalogWrite(pin: pin, value: value)
        }
    }

    private func limbs5(_ v: UInt32) -> [UInt8] {
        (0..<5).map { UInt8((v >> (7 * $0)) & 0x7F) }
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
    private func queryPinState(pin: UInt8) async throws -> PinState {
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
    /// `delay` is inserted between a register write and the subsequent read.
    public func configureI2C(delay: Duration = .zero) async throws {
        let us = delay.firmataMicroseconds
        try await transport.send([
            Cmd.startSysEx, SysEx.i2cConfig,
            UInt8(us & 0x7F), UInt8((us >> 7) & 0x7F),
            Cmd.endSysEx,
        ])
    }

    /// Write bytes to an I2C device.
    public func i2cWrite(address: UInt16, data: [UInt8], is10Bit: Bool = false) async throws {
        try await sendI2CRequest(address: address, mode: .write, is10Bit: is10Bit,
                                 autoRestart: false, payload: encode8BitBytes(data))
    }

    /**
     Read bytes from an I2C device (one-shot). Returns the reply.
     If `registerAddress` is provided it is written before the read request.
     - Note: `registerAddress` is an address *inside the I2C peripheral* (a sub-address
       like a sensor's config register) — **not** one of the board's on-device logic
       registers (``TaskNumberRegister``).
     */
    public func i2cReadOnce(
        address: UInt16,
        registerAddress: UInt16? = nil,
        count: UInt16,
        is10Bit: Bool = false
    ) async throws -> I2CReply {
        if let reg = registerAddress {
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

    /**
     Start continuous I2C reads. Replies arrive on the ``messages`` stream.
     If `registerAddress` is provided it is written before starting reads.
     - Note: `registerAddress` is an address *inside the I2C peripheral* — **not** one of
       the board's on-device logic registers (``TaskNumberRegister``).
     */
    public func i2cStartReading(
        address: UInt16,
        registerAddress: UInt16? = nil,
        count: UInt16,
        is10Bit: Bool = false
    ) async throws {
        if let reg = registerAddress {
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

    /* MARK: - Scheduler
       Store tasks (recorded Firmata messages + delays) on the device and let it
       run them autonomously — even after this client disconnects. */

    /**
     Record a task, upload it, and schedule it — the board replays it on its own,
     surviving disconnects (tasks live in RAM until replaced, deleted, or reboot).

     Recording is synchronous: the closure captures calls as bytes, one `await`
     ships them. `uploadTask` replaces any task with the same id and round-trips a
     confirmation, so it is safe to `disconnect()` right after it returns.

     ```swift
     try await client.uploadTask(id: 2, repeatEvery: .milliseconds(500)) { board in
         board.setPinMode(.pin(2), mode: .output)
         board.digitalWrite(pin: .pin(2), high: true)
         board.delay(.milliseconds(500))                 // the board waits here
         board.digitalWrite(pin: .pin(2), high: false)
     }
     ```

     - Parameters:
       - id: Task id `0–127`; an existing task with this id is replaced.
       - startDelay: Delay before the first run (`.zero` = next scheduler pass).
       - repeatEvery: Loop period (a trailing scheduler delay); `nil` = one-shot,
         removed after it runs.
       - build: Records the actions into the provided ``FirmataTaskRecorder``.
     - Throws: A transport error, or ``FirmataError/transportClosed`` if the link drops.
     */
    public func uploadTask(
        id: UInt8 = 1,
        startDelay: Duration = .zero,
        repeatEvery: Duration? = nil,
        _ build: (FirmataTaskRecorder) -> Void
    ) async throws {
        let recorder = FirmataTaskRecorder()
        build(recorder)
        if let period = repeatEvery { recorder.delay(period) }
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
        try await scheduleTask(id: id, delay: startDelay)

        /* Confirm the device has received and stored everything via a round-trip,
           so it is safe to `disconnect()` immediately after this call returns.
           (Otherwise tearing down the connection can drop still-buffered writes.) */
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

    /// Schedule a task to start `delay` from now (resets its position to 0).
    public func scheduleTask(id: UInt8, delay: Duration) async throws {
        var bytes: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.schedule, id]
        bytes += encode7BitFirmata(timeBytes(delay.firmataMilliseconds))
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

    /**
     Send an I2C_REQUEST. `payload` holds the bytes that follow the control
     byte, already in 7-bit form, exactly as they go on the wire:
       • write data  → each 8-bit byte as a 7-bit LSB/MSB pair (``encode8BitBytes``)
       • register / byte-count → a single 14-bit value as a 7-bit pair (``encode7BitPair``)
     This mirrors the standard Firmata I2C framing parsed by StandardFirmata
     and ConfigurableFirmata.
     */
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

// MARK: - Typed pin / channel (live client)

/**
 A board **pin**, by number — write it as `.pin(13)`. The live-client's typed pin
 identity, so a call never takes a bare integer where a pin is meant (distinct from a
 ``FirmataChannel``). This is the live-client analogue of the task recorder's ``TaskPin``;
 they're deliberately separate types for the two APIs.
 */
public struct FirmataPin: Sendable {
    public let number: UInt8
    public init(_ number: UInt8) {
        precondition(number <= 127, "pin must be 0…127 (Firmata uses a 7-bit pin number)")
        self.number = number
    }
    /// A pin by number — `.pin(13)`.
    public static func pin(_ number: UInt8) -> FirmataPin { FirmataPin(number) }
}

/**
 An **analog channel** index (`A0 = 0`, …) — write it as `.channel(0)`. The live-client's
 typed channel identity (distinct from a ``FirmataPin``); the analogue of the recorder's
 ``TaskChannel``.
 */
public struct FirmataChannel: Sendable {
    public let number: UInt8
    public init(_ number: UInt8) {
        // Channels 0…15 use the standard analog message; ≥16 auto-upgrade to extended
        // analog (the channel is then treated as a 7-bit pin), so allow the full 0…127.
        precondition(number <= 127, "analog channel must be 0…127")
        self.number = number
    }
    /// An analog channel by number — `.channel(0)`.
    public static func channel(_ number: UInt8) -> FirmataChannel { FirmataChannel(number) }
}

/* The public pin/channel API — typed ``FirmataPin`` / ``FirmataChannel`` (`.pin(13)` /
   `.channel(0)`) for call-site clarity and to keep pins distinct from plain numbers. These
   forward to private bare-`UInt8` implementations. */
public extension FirmataClient {
    /// Set a pin's mode — `.pin(13)`.
    func setPinMode(_ pin: FirmataPin, mode: PinMode) async throws {
        try await setPinMode(pin.number, mode: mode)
    }
    /// Drive an output pin HIGH/LOW — `.pin(2)`.
    func digitalWrite(pin: FirmataPin, high: Bool) async throws {
        try await digitalWrite(pin: pin.number, high: high)
    }
    /// One-shot digital read — `.pin(7)`.
    func digitalRead(pin: FirmataPin, timeout: Duration = .seconds(2)) async throws -> Bool {
        try await digitalRead(pin: pin.number, timeout: timeout)
    }
    /// PWM write — `.channel(3)`.
    func analogWrite(channel: FirmataChannel, value: UInt16) async throws {
        try await analogWrite(channel: channel.number, value: value)
    }
    /// Extended analog write (pins ≥ 16 / wide values) — `.pin(9)`.
    func extendedAnalogWrite(pin: FirmataPin, value: Int32) async throws {
        try await extendedAnalogWrite(pin: pin.number, value: value)
    }
    /// Enable/disable reporting for an analog channel — `.channel(0)`.
    func reportAnalogChannel(_ channel: FirmataChannel, enable: Bool) async throws {
        try await reportAnalogChannel(channel.number, enable: enable)
    }
    /// One-shot analog read — `.channel(0)`.
    func analogRead(channel: FirmataChannel, timeout: Duration = .seconds(2)) async throws -> UInt16 {
        try await analogRead(channel: channel.number, timeout: timeout)
    }
    /// Query a pin's current mode + value — `.pin(7)`.
    func queryPinState(pin: FirmataPin) async throws -> PinState {
        try await queryPinState(pin: pin.number)
    }
    /// Servo write — `.pin(13)`; `0…180` = degrees, `≥ 544` = pulse µs.
    func servoWrite(pin: FirmataPin, value: Int32) async throws {
        try await servoWrite(pin: pin.number, value: value)
    }
    /// Servo pulse-range config — `.pin(13)`.
    func configureServo(pin: FirmataPin,
                        minPulseMicros: UInt16 = 544,
                        maxPulseMicros: UInt16 = 2400) async throws {
        try await configureServo(pin: pin.number,
                                 minPulseMicros: minPulseMicros,
                                 maxPulseMicros: maxPulseMicros)
    }
    /// PWM frequency/resolution config — `.pin(4)`. Firmware 2.16+.
    func configurePWM(pin: FirmataPin, frequencyHz: UInt32, resolutionBits: UInt8 = 8) async throws {
        try await configurePWM(pin: pin.number, frequencyHz: frequencyHz, resolutionBits: resolutionBits)
    }
}
