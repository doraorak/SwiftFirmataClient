// MARK: - Firmata Scheduler
//
// The Firmata Scheduler extension (SysEx 0x7B) lets the device store *tasks* —
// recorded sequences of Firmata messages with delays between them — and replay
// them autonomously, even after the host disconnects.
//
// Build a task with ``FirmataTaskRecorder`` (or the high-level
// ``FirmataClient/uploadTask(id:startDelayMs:repeatEveryMs:_:)``), upload it,
// then disconnect — the board keeps running it.

/// A task read back from the device via ``FirmataClient/queryTask(id:)``.
public struct SchedulerTask: Sendable {
    public let id: UInt8
    /// Absolute device time (its `millis()`) at which the task is next due; 0 = not scheduled.
    public let timeMs: UInt32
    /// Total length of the stored task data.
    public let length: Int
    /// Current execution cursor within the task data.
    public let position: Int
    /// The raw recorded Firmata bytes that make up the task.
    public let data: [UInt8]
}

/// Records the Firmata messages that make up a scheduler task.
///
/// You don't create one yourself — ``FirmataClient/uploadTask(id:startDelayMs:repeatEveryMs:_:)``
/// hands you a recorder inside its trailing closure:
///
/// ```swift
/// try await client.uploadTask(id: 1) { t in
/// //                                  ^ this is the recorder
///     t.setPinMode(2, mode: .output)
///     t.digitalWrite(pin: 2, high: true)
/// }
/// ```
///
/// **What is `t in`?** It's just Swift closure syntax: `{ t in … }` declares a
/// closure whose one parameter is named `t`. Here that parameter *is* the
/// `FirmataTaskRecorder`, so inside the braces you call `t.setPinMode(…)`,
/// `t.digitalWrite(…)`, `t.delay(…)`, etc. to record each step. The name `t` is
/// arbitrary — `{ recorder in … }` or the shorthand `{ $0.digitalWrite(…) }` mean
/// the same thing. (`inout` lets your calls mutate the recorder in place.)
///
/// The methods mirror the live ``FirmataClient`` calls but **capture the bytes
/// instead of sending them** — so they're synchronous (no `await`). Insert
/// ``delay(ms:)`` between actions to make the device wait while the task runs.
public struct FirmataTaskRecorder: Sendable {
    /// The recorded bytes so far (the task program). Usually you don't touch this
    /// directly — `uploadTask` reads it for you.
    public private(set) var bytes: [UInt8] = []

    /// Next register handed out by ``digitalRead(pin:)`` / ``analogRead(channel:)``
    /// (descends `R15 → R0`, then wraps).
    private var nextAutoRegister: UInt8 = 15

    public init() {}

    /// Record a pin-mode change (e.g. `.output` before writing it).
    /// - Parameters:
    ///   - pin: The board pin number.
    ///   - mode: The role the pin should take — see ``PinMode``.
    public mutating func setPinMode(_ pin: UInt8, mode: PinMode) {
        bytes += [Cmd.setPinMode, pin, mode.rawValue]
    }

    /// Record driving a pin HIGH or LOW (the pin must be in `.output` mode).
    /// - Parameters:
    ///   - pin: The board pin number to drive.
    ///   - high: `true` for HIGH, `false` for LOW.
    public mutating func digitalWrite(pin: UInt8, high: Bool) {
        bytes += [Cmd.setDigitalPinValue, pin, high ? 0x01 : 0x00]
    }

    /// Record writing all eight pins of a port at once (output pins only).
    /// - Parameters:
    ///   - port: The 8-pin group (`0` = pins 0-7, …).
    ///   - pinMask: One bit per pin (`1` = HIGH, `0` = LOW).
    public mutating func writeDigitalPort(_ port: UInt8, pinMask: UInt8) {
        bytes += [Cmd.digitalMessage | (port & 0x0F), pinMask & 0x7F, (pinMask >> 7) & 0x01]
    }

    /// Record a PWM write to a channel (0-15) in `.pwm` mode.
    /// - Parameters:
    ///   - channel: The PWM channel (pin number for 0-15).
    ///   - value: Duty cycle within the pin's PWM resolution (e.g. `0`-`255`).
    public mutating func analogWrite(channel: UInt8, value: UInt16) {
        bytes += [Cmd.analogMessage | (channel & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
    }

    /// Record a pause — the device waits this long before the next recorded action.
    /// A `delay` as the **final** message makes the whole task loop with that period
    /// (which is what ``FirmataClient/uploadTask(id:startDelayMs:repeatEveryMs:_:)``'s
    /// `repeatEveryMs` adds for you).
    /// - Parameter ms: How long to wait, in milliseconds.
    public mutating func delay(ms: UInt32) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.delay]
        bytes += encode7BitFirmata(timeBytes(ms))
        bytes.append(Cmd.endSysEx)
    }

    // MARK: NON-STANDARD logic extension (see NONSTANDARD.md)
    //
    // On-device registers + `if`/`else` so a task can make decisions by itself.
    // These ride under the scheduler's reserved EXTENDED_SCHEDULER_COMMAND (0x7F),
    // so a standard scheduler ignores them gracefully; only this project's firmware
    // acts on them. The Scheduler control protocol itself is unchanged.
    //
    // The device has 16 global Int32 "registers" (`R0`–`R15`), shared across all
    // tasks and reset by a system reset. You put values into them (a constant, or a
    // pin/analog reading) and then branch on them with ``ifTrue(_:_:_:then:elseDo:)``.

    /// Record `register = value` — load a constant into one of the device's 16
    /// global Int32 registers.
    /// - Parameters:
    ///   - register: Destination register index, `0`–`15`.
    ///   - value: The signed 32-bit value to store.
    public mutating func setRegister(_ register: UInt8, to value: Int32) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSet, register & 0x0F]
        bytes += encode7BitFirmata(timeBytes(UInt32(bitPattern: value)))
        bytes.append(Cmd.endSysEx)
    }

    /// Record `register = digitalRead(pin)` (stores `0`/`1`). The pin should be an
    /// input — record `setPinMode(pin, mode: .input)` earlier in the task.
    /// - Parameters:
    ///   - register: Destination register, `0`–`15`.
    ///   - pin: The board pin to read.
    public mutating func readDigital(into register: UInt8, pin: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extReadDigital,
                  register & 0x0F, pin & 0x7F, Cmd.endSysEx]
    }

    /// Record `register = analogRead(channel)` — read an analog input into a register.
    ///
    /// - Important: `channel` is an **analog channel index, not a pin number**.
    ///   Channels are numbered `A0 = 0`, `A1 = 1`, … and map to specific GPIOs on the
    ///   board (the mapping comes from ``FirmataClient/queryAnalogMapping()``). So
    ///   `channel: 0` reads whatever pin is wired to A0 — not GPIO 0.
    /// - Parameters:
    ///   - register: Destination register index, `0`–`15`.
    ///   - channel: Analog channel (`A0 = 0`, …).
    public mutating func readAnalog(into register: UInt8, channel: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extReadAnalog,
                  register & 0x0F, channel & 0x0F, Cmd.endSysEx]
    }

    /// Record `digitalRead(pin)` into an **auto-allocated** register and return that
    /// register as a ``SchedulerOperand`` — so you can drop the read straight into a
    /// comparison. (A recorder can't return a live value; the read happens on the
    /// device when the task runs, and this hands you the register it lands in.)
    ///
    /// ```swift
    /// let pressed = t.digitalRead(pin: 7)              // -> .reg(n)
    /// t.ifTrue(pressed, .equal, .const(0),             // active-low button
    ///     then: { $0.digitalWrite(pin: 2, high: true) })
    /// ```
    ///
    /// Auto-allocated registers cycle `R15 → R0`; for explicit control use
    /// ``readDigital(into:pin:)``. Read into a local first if you'll reuse it, since
    /// a later auto-read may reuse the same register.
    /// - Parameter pin: The board pin to read (put it in `.input`/`.inputPullup` first).
    /// - Returns: The register operand holding `0`/`1`.
    public mutating func digitalRead(pin: UInt8) -> SchedulerOperand {
        let r = allocateRegister(); readDigital(into: r, pin: pin); return .reg(r)
    }

    /// Record `analogRead(channel)` into an **auto-allocated** register and return
    /// that register as a ``SchedulerOperand`` for use in
    /// ``ifTrue(_:_:_:then:elseDo:)``. See ``digitalRead(pin:)`` for the allocation
    /// rules; use ``readAnalog(into:channel:)`` to choose the register yourself.
    /// - Parameter channel: Analog channel index (`A0 = 0`, …), **not** a pin number.
    /// - Returns: The register operand holding the reading.
    public mutating func analogRead(channel: UInt8) -> SchedulerOperand {
        let r = allocateRegister(); readAnalog(into: r, channel: channel); return .reg(r)
    }

    /// Hand out the next auto-allocated register, descending `R15 → R0` then wrapping
    /// (kept high to avoid clashing with low registers you set explicitly).
    private mutating func allocateRegister() -> UInt8 {
        let r = nextAutoRegister
        nextAutoRegister = (nextAutoRegister == 0) ? 15 : (nextAutoRegister - 1)
        return r
    }

    /// Record an `if` (optionally with `else`) that the **device** evaluates while
    /// the task runs. It compares the two operands with `op`; the `then` block runs
    /// only when the comparison is true, otherwise the `elseDo` block (if given) runs.
    ///
    /// ```swift
    /// t.readAnalog(into: 0, channel: 0)                    // R0 = analog A0
    /// t.ifTrue(.reg(0), .greaterThan, .const(512),         // if R0 > 512
    ///     then:   { b in b.digitalWrite(pin: 2, high: true) },   // …LED on
    ///     elseDo: { b in b.digitalWrite(pin: 2, high: false) })  // …else off
    /// ```
    ///
    /// Each branch is itself a recorder closure: the `b` (or shorthand `$0`) passed
    /// to `then`/`elseDo` is a nested ``FirmataTaskRecorder`` — record that branch's
    /// steps on it exactly like the outer `t`. Branches may contain anything,
    /// including ``delay(ms:)`` and further `ifTrue` calls (nesting works).
    ///
    /// - Parameters:
    ///   - a: Left operand — a register `.reg(0...15)` or a literal `.const(value)`.
    ///   - op: How to compare them — `.equal`, `.notEqual`, `.lessThan`,
    ///     `.greaterThan`, `.lessOrEqual`, or `.greaterOrEqual`.
    ///   - b: Right operand — a register or a literal.
    ///   - then: Records the steps that run when `a op b` is **true**. Its argument
    ///     is the branch's recorder.
    ///   - elseDo: Optional — records the steps that run when the comparison is
    ///     **false**. Omit it for a plain `if` with no `else`.
    public mutating func ifTrue(
        _ a: SchedulerOperand,
        _ op: SchedulerComparison,
        _ b: SchedulerOperand,
        then: (inout FirmataTaskRecorder) -> Void,
        elseDo: ((inout FirmataTaskRecorder) -> Void)? = nil
    ) {
        var thenRec = FirmataTaskRecorder(); then(&thenRec)
        var thenBytes = thenRec.bytes

        var elseBytes: [UInt8] = []
        if let elseDo {
            var elseRec = FirmataTaskRecorder(); elseDo(&elseRec)
            elseBytes = elseRec.bytes
        }
        // If there's an else, the then-branch ends by skipping over the else block.
        if !elseBytes.isEmpty {
            thenBytes += Self.skipMessage(byteCount: elseBytes.count)
        }
        // IF: when the comparison is false, skip the whole then-branch.
        bytes += Self.ifMessage(a, op, b, skipBytes: thenBytes.count)
        bytes += thenBytes
        bytes += elseBytes
    }

    /// Record an **internet request** the device makes over its own Wi-Fi while
    /// the task runs (non-standard extension). The device performs the HTTP(S)
    /// `GET`, then stores results in two registers so later ``ifTrue(_:_:_:then:elseDo:)``
    /// steps can branch on them — so a task can react to data from the internet
    /// with no host connected:
    ///
    /// - `R[statusInto]` ← the HTTP status code (`200`, `404`, …; `0` if Wi-Fi is
    ///   down or the request failed).
    /// - `R[valueInto]` ← the first integer found in the response body (`0` if none).
    ///   Handy when an endpoint returns a number (a price, count, sensor value…).
    ///
    /// If a host happens to be connected while the task runs, the full status +
    /// body are also delivered to it as ``FirmataMessage/httpResponse(status:body:)``.
    ///
    /// ```swift
    /// // Turn on pin 2 only when an endpoint reports a value over 100.
    /// try await client.uploadTask(id: 5, repeatEveryMs: 60_000) { t in
    ///     t.setPinMode(2, mode: .output)
    ///     t.httpGet("http://example.com/sensor", statusInto: 0, valueInto: 1)
    ///     t.ifTrue(.reg(1), .greaterThan, .const(100),
    ///         then:   { $0.digitalWrite(pin: 2, high: true) },
    ///         elseDo: { $0.digitalWrite(pin: 2, high: false) })
    /// }
    /// ```
    ///
    /// - Important: The URL must be ASCII and short enough to fit one SysEx frame
    ///   (URL + body ≲ 500 bytes). The request **blocks the device** until it
    ///   completes (up to ~8 s), so keep request-bearing tasks infrequent.
    /// - Parameters:
    ///   - url: The `http://` or `https://` URL to fetch (TLS is not certificate-verified).
    ///   - statusInto: Register (`0`–`15`) to receive the HTTP status code.
    ///   - valueInto: Register (`0`–`15`) to receive the first integer in the body.
    public mutating func httpGet(_ url: String, statusInto: UInt8, valueInto: UInt8) {
        bytes += httpOpBytes(method: 0, statusReg: statusInto, valueReg: valueInto, url: url, body: nil)
    }

    /// Record an **internet `POST`** the device makes over Wi-Fi while the task
    /// runs (non-standard extension). The `body` is sent with
    /// `Content-Type: application/json`. Results land in registers exactly as for
    /// ``httpGet(_:statusInto:valueInto:)``.
    /// - Parameters:
    ///   - url: The `http://`/`https://` URL to post to (ASCII; TLS not verified).
    ///   - body: The request body (e.g. a JSON string). ASCII.
    ///   - statusInto: Register (`0`–`15`) to receive the HTTP status code.
    ///   - valueInto: Register (`0`–`15`) to receive the first integer in the response.
    public mutating func httpPost(_ url: String, body: String, statusInto: UInt8, valueInto: UInt8) {
        bytes += httpOpBytes(method: 1, statusReg: statusInto, valueReg: valueInto, url: url, body: body)
    }

    // MARK: Extension byte builders

    private static func operandBytes(_ o: SchedulerOperand) -> [UInt8] {
        switch o {
        case .reg(let r):   return [0, r & 0x0F]
        case .const(let v): return [1] + encode7BitFirmata(timeBytes(UInt32(bitPattern: v)))
        }
    }

    private static func ifMessage(_ a: SchedulerOperand, _ op: SchedulerComparison,
                                  _ b: SchedulerOperand, skipBytes: Int) -> [UInt8] {
        let n = UInt16(min(skipBytes, 0x3FFF))
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extIf, op.rawValue]
        m += operandBytes(a)
        m += operandBytes(b)
        m += [UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
        return m
    }

    private static func skipMessage(byteCount: Int) -> [UInt8] {
        let n = UInt16(min(byteCount, 0x3FFF))
        return [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSkip,
                UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
    }
}

/// An operand for ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)`` — either one of
/// the device's 16 registers or a literal value. (Non-standard extension.)
public enum SchedulerOperand: Sendable {
    /// One of the device's registers, by index (`0`–`15`).
    case reg(UInt8)
    /// A fixed signed 32-bit literal compared as-is.
    case const(Int32)
}

/// A comparison for ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``.
/// (Non-standard extension.)
public enum SchedulerComparison: UInt8, Sendable {
    case equal          = 0
    case notEqual       = 1
    case lessThan       = 2
    case greaterThan    = 3
    case lessOrEqual    = 4
    case greaterOrEqual = 5
}

// MARK: - Internet-action op encoding (non-standard extension)

/// Encode a `SCHED_EXT_HTTP` op (used both inside tasks and for live requests).
/// Layout: `F0 7B 7F 15 method statusReg valueReg urlLo urlHi url[…] bodyLo bodyHi body[…] F7`.
/// URL/body are sent as raw 7-bit ASCII; lengths are 14-bit little-endian.
func httpOpBytes(method: UInt8, statusReg: UInt8, valueReg: UInt8,
                 url: String, body: String?) -> [UInt8] {
    let u = Array(url.utf8)
    let b = Array((body ?? "").utf8)
    var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHttp,
                      method, statusReg & 0x0F, valueReg & 0x0F]
    m += [UInt8(u.count & 0x7F), UInt8((u.count >> 7) & 0x7F)]
    m += u.map { $0 & 0x7F }
    m += [UInt8(b.count & 0x7F), UInt8((b.count >> 7) & 0x7F)]
    m += b.map { $0 & 0x7F }
    m.append(Cmd.endSysEx)
    return m
}

// MARK: - Encoder7Bit (8-bit data packed into 7-bit bytes)

/// Pack arbitrary 8-bit bytes into 7-bit bytes, as used for Firmata Scheduler
/// task data and 32-bit time values.
func encode7BitFirmata(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(data.count * 8 / 7 + 1)
    var shift: UInt8 = 0
    var previous: UInt8 = 0
    for b in data {
        if shift == 0 {
            out.append(b & 0x7F)
            shift = 1
            previous = b >> 7
        } else {
            out.append(UInt8((UInt16(b) << UInt16(shift)) & 0x7F) | previous)
            if shift == 6 {
                out.append(b >> 1)
                shift = 0
            } else {
                shift += 1
                previous = b >> (8 - shift)
            }
        }
    }
    if shift > 0 { out.append(previous) }
    return out
}

/// Unpack `outBytes` 8-bit bytes from a 7-bit-packed buffer.
func decode7BitFirmata(_ outBytes: Int, _ input: [UInt8]) -> [UInt8] {
    guard outBytes > 0 else { return [] }
    var out = [UInt8](repeating: 0, count: outBytes)
    for i in 0..<outBytes {
        let j = i << 3
        let pos = j / 7
        let shift = j % 7
        let hi: UInt8 = (pos + 1 < input.count) ? input[pos + 1] : 0
        let lo: UInt8 = (pos < input.count) ? (input[pos] >> UInt8(shift)) : 0
        out[i] = lo | UInt8((UInt16(hi) << UInt16(7 - shift)) & 0xFF)
    }
    return out
}

/// Number of decoded 8-bit bytes a 7-bit-packed buffer of `encodedLen` yields.
func num7BitOutBytes(_ encodedLen: Int) -> Int { (encodedLen * 7) / 8 }

/// Little-endian 4-byte representation of a 32-bit value (for time fields).
func timeBytes(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF),
     UInt8((value >> 8) & 0xFF),
     UInt8((value >> 16) & 0xFF),
     UInt8((value >> 24) & 0xFF)]
}
