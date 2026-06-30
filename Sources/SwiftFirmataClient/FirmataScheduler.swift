// MARK: - Firmata Scheduler
//
// The Firmata Scheduler extension (SysEx 0x7B) lets the device store *tasks* —
// recorded sequences of Firmata messages with delays between them — and replay
// them autonomously, even after the host disconnects.
//
// Build a task with ``FirmataTaskRecorder`` (or the high-level
// ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``), upload it,
// then disconnect — the board keeps running it.

// The Firmata wire protocol carries time as raw integer milliseconds (scheduler
// delays, sampling interval) or microseconds (I2C config). The public API takes
// `Duration`; these convert to the wire unit, truncating sub-unit precision.
extension Duration {
    /// Whole milliseconds (truncated toward zero), saturating into `UInt32`.
    internal var firmataMilliseconds: UInt32 {
        let (s, atto) = components
        return UInt32(clamping: s * 1_000 + atto / 1_000_000_000_000_000)
    }
    /// Whole microseconds (truncated toward zero), saturating into `UInt16`.
    internal var firmataMicroseconds: UInt16 {
        let (s, atto) = components
        return UInt16(clamping: s * 1_000_000 + atto / 1_000_000_000_000)
    }
}

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
/// You don't create one yourself — ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``
/// hands you a recorder inside its trailing closure:
///
/// ```swift
/// try await client.uploadTask(id: 1) { board in
/// //                                  ^ this is the recorder
///     board.setPinMode(2, mode: .output)
///     board.digitalWrite(pin: 2, high: true)
/// }
/// ```
///
/// **What is `board in`?** It's just Swift closure syntax: `{ board in … }` declares a
/// closure whose one parameter is named `board`. Here that parameter *is* the
/// `FirmataTaskRecorder`, so inside the braces you call `board.setPinMode(…)`,
/// `board.digitalWrite(…)`, `board.delay(…)`, etc. to record each step. The name `board` is
/// arbitrary — `{ recorder in … }` or the shorthand `{ $0.digitalWrite(…) }` mean
/// the same thing. (The recorder is a reference type, so your calls mutate it in place.)
///
/// The methods mirror the live ``FirmataClient`` calls but **capture the bytes
/// instead of sending them** — so they're synchronous (no `await`). Insert
/// ``delay(_:)`` between actions to make the device wait while the task runs.
public final class FirmataTaskRecorder {
    /// The recorded bytes so far (the task program). Usually you don't touch this
    /// directly — `uploadTask` reads it for you.
    public internal(set) var bytes: [UInt8] = []

    /// Append recorded op bytes — used by the `board.json` / `board.string` op builders.
    internal func emit(_ b: [UInt8]) { bytes += b }

    /// Next register handed out by ``digitalRead(pin:)`` / ``analogRead(channel:)``
    /// (descends `R15 → R0`, then wraps).
    private var nextAutoRegister: TaskNumberRegister = .reg(15)
    /// Next float register auto-allocated for `getFloat` / float arithmetic
    /// (descends `F7 → F0`, then wraps).
    private var nextAutoFloatRegister: TaskFloatRegister = .freg(7)
    /// Next JSON snapshot slot (0–1) and string slot (0–9), each wrapping.
    private var nextTaskJSONSlot: UInt8 = 0
    private var nextTaskStringSlot: UInt8 = 0
    /// Generation registers (for handle staleness) allocate bottom-up (R0↑) so they
    /// don't collide with the top-down (R15↓) pool used by reads/arithmetic results.
    private var nextRequestCountRegister: TaskNumberRegister = .reg(0)

    public init() {}

    /// Nested-branch recorder: inherits the parent's auto-allocation cursors so a
    /// branch never reuses a register/slot the parent already handed out (registers
    /// and slots are **global on the device**, shared across the whole task). The
    /// parent picks the advanced cursors back up with ``adoptCursors(from:)`` once the
    /// branch is recorded.
    private init(inheriting parent: FirmataTaskRecorder) {
        nextAutoRegister         = parent.nextAutoRegister
        nextAutoFloatRegister    = parent.nextAutoFloatRegister
        nextTaskJSONSlot         = parent.nextTaskJSONSlot
        nextTaskStringSlot       = parent.nextTaskStringSlot
        nextRequestCountRegister = parent.nextRequestCountRegister
    }

    /// Resume allocation where a nested-branch recorder left off, so registers/slots
    /// handed out inside a branch are never reused by later outer-scope allocations.
    private func adoptCursors(from child: FirmataTaskRecorder) {
        nextAutoRegister         = child.nextAutoRegister
        nextAutoFloatRegister    = child.nextAutoFloatRegister
        nextTaskJSONSlot         = child.nextTaskJSONSlot
        nextTaskStringSlot       = child.nextTaskStringSlot
        nextRequestCountRegister = child.nextRequestCountRegister
    }

    /// Record a pin-mode change (e.g. `.output` before writing it).
    /// - Parameters:
    ///   - pin: The board pin number.
    ///   - mode: The role the pin should take — see ``PinMode``.
    public func setPinMode(_ pin: UInt8, mode: PinMode) {
        bytes += [Cmd.setPinMode, pin, mode.rawValue]
    }

    /// Record driving a pin HIGH or LOW (the pin must be in `.output` mode).
    /// - Parameters:
    ///   - pin: The board pin number to drive.
    ///   - high: `true` for HIGH, `false` for LOW.
    public func digitalWrite(pin: UInt8, high: Bool) {
        bytes += [Cmd.setDigitalPinValue, pin, high ? 0x01 : 0x00]
    }

    /// Record writing all eight pins of a port at once (output pins only).
    /// - Parameters:
    ///   - port: The 8-pin group (`0` = pins 0-7, …).
    ///   - pinMask: One bit per pin (`1` = HIGH, `0` = LOW).
    public func writeDigitalPort(_ port: UInt8, pinMask: UInt8) {
        bytes += [Cmd.digitalMessage | (port & 0x0F), pinMask & 0x7F, (pinMask >> 7) & 0x01]
    }

    /// Record a PWM write to a channel (0-15) in `.pwm` mode.
    /// - Parameters:
    ///   - channel: The PWM channel (pin number for 0-15).
    ///   - value: Duty cycle within the pin's PWM resolution (e.g. `0`-`255`).
    public func analogWrite(channel: UInt8, value: UInt16) {
        bytes += [Cmd.analogMessage | (channel & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
    }

    /// Record a pause — the device waits this long before the next recorded action.
    /// A `delay` as the **final** message makes the whole task loop with that period
    /// (which is what ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``'s
    /// `repeatEvery` adds for you).
    /// - Parameter duration: How long to wait (truncated to whole milliseconds — the
    ///   resolution of the Firmata scheduler wire protocol).
    public func delay(_ duration: Duration) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.delay]
        bytes += encode7BitFirmata(timeBytes(duration.firmataMilliseconds))
        bytes.append(Cmd.endSysEx)
    }

    // MARK: I2C (standard Firmata — drive an I2C device from a task)
    //
    // The scheduler replays these through the device's Firmata parser, so a task
    // can talk to an I2C peripheral (e.g. write command/data bytes to an SSD1306
    // OLED) with no host connected. Call `i2cConfig` once (it begins the bus),
    // then `i2cWrite` as needed. (Reads aren't offered here — their reply has no
    // host to receive it inside an autonomous task.)

    /// Record an I2C bus config/begin (`delay` between a register-write and the
    /// following read; truncated to whole microseconds). Do this once at the start of
    /// a task that uses I2C.
    public func i2cConfig(delay: Duration = .zero) {
        let us = delay.firmataMicroseconds
        bytes += [Cmd.startSysEx, SysEx.i2cConfig,
                  UInt8(us & 0x7F), UInt8((us >> 7) & 0x7F),
                  Cmd.endSysEx]
    }

    /// Record an I2C write of `data` to `address` (each byte sent as a 7-bit
    /// LSB/MSB pair, per Firmata I2C framing).
    public func i2cWrite(address: UInt16, data: [UInt8], is10Bit: Bool = false) {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.i2cRequest, UInt8(address & 0x7F)]
        var control: UInt8 = (I2CMode.write.rawValue & 0x03) << 3   // write mode, no auto-restart
        if is10Bit { control |= 0x20; control |= UInt8((address >> 7) & 0x07) }
        m.append(control)
        for b in data { m.append(b & 0x7F); m.append((b >> 7) & 0x01) }
        m.append(Cmd.endSysEx)
        bytes += m
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

    /// Record `R[dst] = value` — load a constant into one of the device's 16
    /// global Int32 registers.
    /// - Parameters:
    ///   - dst: Destination register index, `0`–`15`.
    ///   - value: The signed 32-bit value to store.
    public func setRegister(_ dst: TaskNumberRegister, to value: TaskNumberLiteral.RawValue) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSet, dst.index & 0x0F]
        bytes += encode7BitFirmata(timeBytes(UInt32(bitPattern: value)))
        bytes.append(Cmd.endSysEx)
    }

    /// Record `register = digitalRead(pin)` (stores `0`/`1`). The pin should be an
    /// input — record `setPinMode(pin, mode: .input)` earlier in the task.
    /// - Parameters:
    ///   - register: Destination register, `0`–`15`.
    ///   - pin: The board pin to read.
    public func digitalRead(into register: TaskBoolRegister, pin: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extDigitalRead,
                  register.index & 0x0F, pin & 0x7F, Cmd.endSysEx]
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
    public func analogRead(into register: TaskNumberRegister, channel: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extAnalogRead,
                  register.index & 0x0F, channel & 0x0F, Cmd.endSysEx]
    }

    /// Record `digitalRead(pin)` into an **auto-allocated** register and return that
    /// register as a ``TaskOperand`` — so you can drop the read straight into a
    /// comparison. (A recorder can't return a live value; the read happens on the
    /// device when the task runs, and this hands you the register it lands in.)
    ///
    /// ```swift
    /// let pressed = board.digitalRead(pin: 7)              // -> .reg(n)
    /// board.ifTrue(pressed, .equal, .number(0),             // active-low button
    ///     then: { $0.digitalWrite(pin: 2, high: true) })
    /// ```
    ///
    /// Auto-allocated registers cycle `R15 → R0`; for explicit control use
    /// ``digitalRead(into:pin:)``. Read into a local first if you'll reuse it, since
    /// a later auto-read may reuse the same register.
    /// - Parameter pin: The board pin to read (put it in `.input`/`.inputPullup` first).
    /// - Returns: The register operand holding `0`/`1`.
    public func digitalRead(pin: UInt8) -> TaskBoolRegister {
        let r = TaskBoolRegister(allocateRegister())
        digitalRead(into: r, pin: pin)
        return r
    }

    /// Record `analogRead(channel)` into an **auto-allocated** register and return
    /// that register as a ``TaskOperand`` for use in
    /// ``ifTrue(_:_:_:then:elseDo:)``. See ``digitalRead(pin:)`` for the allocation
    /// rules; use ``analogRead(into:channel:)`` to choose the register yourself.
    /// - Parameter channel: Analog channel index (`A0 = 0`, …), **not** a pin number.
    /// - Returns: The register operand holding the reading.
    public func analogRead(channel: UInt8) -> TaskNumberRegister {
        let r = allocateRegister(); analogRead(into: r, channel: channel); return r
    }

    /// Hand out the next auto-allocated register, descending `R15 → R0` then wrapping
    /// (kept high to avoid clashing with low registers you set explicitly).
    internal func allocateRegister() -> TaskNumberRegister {
        let r = nextAutoRegister
        let raw = r.index
        nextAutoRegister = .reg((raw == 0) ? 15 : (raw - 1))
        return r
    }

    internal func allocateFloatRegister() -> TaskFloatRegister {
        let r = nextAutoFloatRegister
        let raw = r.index
        nextAutoFloatRegister = .freg((raw == 0) ? 7 : (raw - 1))
        return r
    }

    /// JSON snapshot slots — 2 of them (0–1), wrapping.
    internal func allocateTaskJSONSlot() -> TaskJSONSlot {
        let s = nextTaskJSONSlot
        nextTaskJSONSlot = (nextTaskJSONSlot >= 1) ? 0 : (nextTaskJSONSlot + 1)
        return TaskJSONSlot(s)
    }
    /// String slots — 10 of them (0–9), wrapping.
    internal func allocateTaskStringSlot() -> TaskStringSlot {
        let s = nextTaskStringSlot
        nextTaskStringSlot = (nextTaskStringSlot >= 9) ? 0 : (nextTaskStringSlot + 1)
        return TaskStringSlot(s)
    }

    private func allocateGenRegister() -> TaskNumberRegister {
        let r = nextRequestCountRegister
        let raw = r.index
        nextRequestCountRegister = .reg((raw == 15) ? 0 : (raw + 1))
        return r
    }

    /// Record an `if` (optionally with `else`) that the **device** evaluates while
    /// the task runs. It compares the two operands with `op`; the `then` block runs
    /// only when the comparison is true, otherwise the `elseDo` block (if given) runs.
    ///
    /// ```swift
    /// board.analogRead(into: .reg(0), channel: 0)              // R0 = analog A0
    /// board.ifTrue(.reg(0), .greaterThan, .number(512),         // if R0 > 512
    ///     then:   { b in b.digitalWrite(pin: 2, high: true) },   // …LED on
    ///     elseDo: { b in b.digitalWrite(pin: 2, high: false) })  // …else off
    /// ```
    ///
    /// Each branch is itself a recorder closure: the `b` (or shorthand `$0`) passed
    /// to `then`/`elseDo` is a nested ``FirmataTaskRecorder`` — record that branch's
    /// steps on it exactly like the outer `board`. Branches may contain anything,
    /// including ``delay(_:)`` and further `ifTrue` calls (nesting works).
    ///
    /// - Parameters:
    ///   - a: Left operand — a register `.reg(0...15)` or a literal `.number(value)`.
    ///   - op: How to compare them — `.equal`, `.notEqual`, `.lessThan`,
    ///     `.greaterThan`, `.lessOrEqual`, or `.greaterOrEqual`.
    ///   - b: Right operand — a register or a literal.
    ///   - then: Records the steps that run when `a op b` is **true**. Its argument
    ///     is the branch's recorder.
    ///   - elseDo: Optional — records the steps that run when the comparison is
    ///     **false**. Omit it for a plain `if` with no `else`.
    public func ifTrue(
        _ a: TaskOperand,
        _ op: TaskComparison,
        _ b: TaskOperand,
        then: (FirmataTaskRecorder) -> Void,
        elseDo: ((FirmataTaskRecorder) -> Void)? = nil
    ) {
        // Branch recorders inherit our allocation cursors and hand them back, so a
        // register/slot used in a branch is never reused by the outer scope (or the
        // other branch) — they all name the same global device registers/slots.
        let thenRec = FirmataTaskRecorder(inheriting: self); then(thenRec)
        adoptCursors(from: thenRec)
        var thenBytes = thenRec.bytes

        var elseBytes: [UInt8] = []
        if let elseDo {
            let elseRec = FirmataTaskRecorder(inheriting: self); elseDo(elseRec)
            adoptCursors(from: elseRec)
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

    /// Record an `if` driven by a **boolean operand** — the `then` block runs when
    /// `condition` is true (non-zero), otherwise `elseDo` (if given). Pass a value from
    /// any predicate op: ``digitalRead(pin:)``, `string.equals`, `bodyContains`,
    /// ``compare(_:_:_:into:)``, etc.
    ///
    /// ```swift
    /// let pressed = board.digitalRead(pin: 7)        // -> TaskBool
    /// board.ifTrue(pressed) { $0.digitalWrite(pin: 2, high: true) }
    /// ```
    ///
    /// This is shorthand for ``ifTrue(_:_:_:then:elseDo:)`` with `.notEqual, .number(0)`.
    /// - Parameters:
    ///   - condition: A boolean operand (a `0`/non-zero register or literal).
    ///   - then: Steps to run when `condition` is true.
    ///   - elseDo: Optional steps to run when `condition` is false.
    public func ifTrue(
        _ condition: TaskBool,
        then: (FirmataTaskRecorder) -> Void,
        elseDo: ((FirmataTaskRecorder) -> Void)? = nil
    ) {
        ifTrue(condition, .notEqual, .number(0), then: then, elseDo: elseDo)
    }

    /// Record `R[dst] = (a op b) ? 1 : 0` and return it as a **reusable boolean** — store
    /// it once and branch on it (possibly several times) with ``ifTrue(_:then:elseDo:)``,
    /// instead of repeating the comparison inline. Operands may be registers or literals;
    /// if either side is a float the device promotes to float. Result register
    /// auto-allocated (R15↓) unless `into:` is given. (Non-standard extension.)
    ///
    /// ```swift
    /// let isUp = board.compare(pct, .greaterThan, .number(0))   // -> TaskBool
    /// board.ifTrue(isUp) { $0.digitalWrite(pin: 2, high: true) }
    /// ```
    @discardableResult
    public func compare(_ a: TaskOperand, _ op: TaskComparison, _ b: TaskOperand,
                        into: TaskBoolRegister? = nil) -> TaskBoolRegister {
        let dst = into ?? TaskBoolRegister(allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extCmp,
                          op.rawValue, dst.index & 0x0F]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record an **internet request** the device makes over its own Wi-Fi while
    /// the task runs (non-standard extension; supports `https://` with cert
    /// validation). The device performs the HTTP(S) `GET`, stores the status in
    /// `R[statusInto]` (`0` if Wi-Fi is down / it failed), and **retains the full
    /// response body** for the inspection ops below. If a host is connected, the
    /// status + body also arrive as ``FirmataMessage/httpResponse(status:body:)``.
    ///
    /// Inspect the response by passing its ``TaskHTTPResponse/body`` to the ``json`` ops
    /// (`board.json.getNumber(resp.body, …)`, `.getFloat`, `.getString`, …) — then branch
    /// with `ifTrue`:
    ///
    /// ```swift
    /// // Green/red LED from SPY's % change, no host connected.
    /// try await client.uploadTask(id: 5, repeatEvery: .seconds(60)) { board in
    ///     board.setPinMode(2, mode: .output); board.setPinMode(4, mode: .output)
    ///     let spy = board.httpGet("https://example.com/quote/SPY")             // -> TaskHTTPResponse
    ///     let pct = board.json.getNumber(spy.body, "changePercent", scaledBy: 2)  // -0.42% -> -42
    ///     board.ifTrue(spy.status, .equal, .number(200)) {                 // only act on success
    ///         $0.ifTrue(pct, .greaterThan, .number(0),
    ///             then:   { $0.digitalWrite(pin: 2, high: true);  $0.digitalWrite(pin: 4, high: false) },
    ///             elseDo: { $0.digitalWrite(pin: 2, high: false); $0.digitalWrite(pin: 4, high: true) })
    ///     }
    /// }
    /// ```
    ///
    /// - Important: URL must be ASCII and fit one SysEx frame (URL + body ≲ 500 B).
    ///   The request **blocks the device** (~8 s max); keep request tasks infrequent.
    /// - Parameters:
    ///   - url: The `http://` or `https://` URL to fetch.
    ///   - statusInto: Register for the HTTP status; auto-allocated (R15↓) if omitted.
    /// - Returns: A ``TaskHTTPResponse`` — branch on `.status`, and pass `.body` to the
    ///   ``json`` ops (`board.json.getNumber(resp.body, …)`) to inspect the payload.
    @discardableResult
    public func httpGet(_ url: String, statusInto: TaskNumberRegister? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 0, statusReg: statusReg, url: url, body: nil)
        return makeResponse(statusReg: statusReg)
    }

    /// Record an **internet `POST`** (Wi-Fi, `Content-Type: application/json`).
    /// Returns a ``TaskHTTPResponse`` (status auto-allocated unless `statusInto:` is given);
    /// inspect the body with the JSON/string ops.
    @discardableResult
    public func httpPost(_ url: String, body: String, statusInto: TaskNumberRegister? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 1, statusReg: statusReg, url: url, body: body)
        return makeResponse(statusReg: statusReg)
    }

    // Capture the body generation into a register so the body handle can be staleness-checked.
    private func makeResponse(statusReg: TaskNumberRegister) -> TaskHTTPResponse {
        let gReg = allocateGenRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, gReg.index & 0x0F, Cmd.endSysEx]
        return TaskHTTPResponse(status: statusReg,
                                body: TaskJSON(genReg: gReg, snapshotSlot: nil, rec: self))
    }

    // MARK: Handle lifecycle — typed select / snapshot / free

    /// Select the JSON body source for the next inspection op: an owned snapshot slot, or
    /// the live body checked for staleness against the handle's captured generation.
    internal func selectJSON(_ body: TaskJSON) {
        if let slot = body.snapshotSlot {
            emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                  slot.firmwareIndex + 1, 0x00, Cmd.endSysEx])
        } else {
            emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                  0x00, body.genReg.index & 0x0F, Cmd.endSysEx])
        }
    }

    /// Select a string's slot for the next `board.string` op.
    internal func selectString(_ s: TaskString) {
        emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
              s.slot.firmwareIndex + 1, 0x00, Cmd.endSysEx])
    }

    /// Read the device's current request count (body generation) into a register.
    /// Used by ``TaskJSON/isValid()`` to compare against a handle's captured generation.
    internal func currentRequestCount(into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        let dst = into ?? allocateRegister()
        emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, dst.index & 0x0F, Cmd.endSysEx])
        return dst
    }

    internal func appendLengthPrefixed(_ m: inout [UInt8], _ s: String) {
        let b = Array(s.utf8)
        m += [UInt8(b.count & 0x7F), UInt8((b.count >> 7) & 0x7F)]
        m += b.map { $0 & 0x7F }      // ASCII expected
    }

    // MARK: Arithmetic (on integer registers)

    /// Record `R[dst] = a + b`. Operands are registers and/or literals; the result
    /// register is auto-allocated (R15↓) unless `into:` is given. Returns it as an
    /// operand for chaining / `ifTrue`. (64-bit intermediates on the device avoid
    /// overflow; `÷` and `%` by zero yield 0.)
    @discardableResult
    public func add(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        arith(0, a, b, into)
    }
    /// Record `R[dst] = a - b`. See ``add(_:_:into:)``.
    @discardableResult
    public func subtract(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        arith(1, a, b, into)
    }
    /// Record `R[dst] = a * b`. See ``add(_:_:into:)``.
    @discardableResult
    public func multiply(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        arith(2, a, b, into)
    }
    /// Record `R[dst] = a / b` (integer division; `÷0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func divide(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        arith(3, a, b, into)
    }
    /// Record `R[dst] = a % b` (`%0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func modulo(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        arith(4, a, b, into)
    }

    private func arith(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                _ into: TaskNumberRegister?) -> TaskNumberRegister {
        let dst = into ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArith, sub, dst.index & 0x0F]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    // MARK: Float registers (8 of them, F0–F7)

    /// Record `F[dst] = value`. Returns the float register as a `.freg` operand.
    @discardableResult
    public func setFloatRegister(_ dst: TaskFloatRegister, to value: TaskFloatLiteral.RawValue) -> TaskFloatRegister {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSetFloat, dst.index & 0x07]
        m += encode7BitFirmata(timeBytes(value.bitPattern))
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record `F[dst] = a + b` (float). Operands may be float/int registers or
    /// literals (ints promote to float). Result float register auto-allocated
    /// (F7↓) unless `into:` is given. `÷0` → 0.
    @discardableResult
    public func addFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloatRegister {
        arithF(0, a, b, into)
    }
    /// Record `F[dst] = a - b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func subtractFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloatRegister {
        arithF(1, a, b, into)
    }
    /// Record `F[dst] = a * b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func multiplyFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloatRegister {
        arithF(2, a, b, into)
    }
    /// Record `F[dst] = a / b` (float; `÷0` → 0). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func divideFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloatRegister {
        arithF(3, a, b, into)
    }

    private func arithF(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                 _ into: TaskFloatRegister?) -> TaskFloatRegister {
        let dst = into ?? allocateFloatRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArithFloat, sub, dst.index & 0x07]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record reading heap stats into registers — `free` heap and `largest`
    /// contiguous block — so a task can gate an allocation on available memory.
    @discardableResult
    public func heapStats(freeInto: TaskNumberRegister? = nil,
                                   largestInto: TaskNumberRegister? = nil) -> (free: TaskNumberRegister, largest: TaskNumberRegister) {
        let f = freeInto ?? allocateRegister()
        let l = largestInto ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHeap,
                  f.index & 0x0F, l.index & 0x0F, Cmd.endSysEx]
        return (f, l)
    }

    // MARK: Extension byte builders

    private static func ifMessage(_ a: TaskOperand, _ op: TaskComparison,
                                  _ b: TaskOperand, skipBytes: Int) -> [UInt8] {
        let n = UInt16(min(skipBytes, 0x3FFF))
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extIf, op.rawValue]
        m += a.operandBytes
        m += b.operandBytes
        m += [UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
        return m
    }

    private static func skipMessage(byteCount: Int) -> [UInt8] {
        let n = UInt16(min(byteCount, 0x3FFF))
        return [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSkip,
                UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
    }

    /// JSON inspection of recorded response bodies — call as
    /// `board.json.getNumber(resp.body, "path")`. (A tiny value-type view over the recorder;
    /// no instance to manage.)
    public var json: TaskJSONOps { TaskJSONOps(rec: self) }

    /// Raw-string inspection of a recorded response body — `board.string` ops over a
    /// ``TaskString`` from ``TaskJSONOps/getString(_:_:into:)``.
    public var string: TaskStringOps { TaskStringOps(rec: self) }
}

/// JSON inspection of a recorded response body (reached via ``FirmataTaskRecorder/json``).
/// Each call takes a ``TaskJSON`` (from ``TaskHTTPResponse/body`` or ``TaskJSONOps/snapshot(_:into:)``):
/// it selects that source on the device — a snapshot, or the live body checked for staleness
/// against the handle's generation — then records the op. Branch on results with `board.ifTrue`.
public struct TaskJSONOps {
    internal let rec: FirmataTaskRecorder

    /// `R` = number at `path` × 10^`scaledBy` (truncated; also parses quoted numbers).
    @discardableResult
    public func getNumber(_ body: TaskJSON, _ path: String, scaledBy: UInt8 = 0,
                          into: TaskNumberRegister? = nil, found: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        let fnd = found ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonNum,
                          dst.index & 0x0F, fnd.index & 0x0F, scaledBy]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `F` = floating-point number at `path` (handles quoted / fractional / exponent).
    @discardableResult
    public func getFloat(_ body: TaskJSON, _ path: String,
                         into: TaskFloatRegister? = nil, found: TaskNumberRegister? = nil) -> TaskFloatRegister {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateFloatRegister()
        let fnd = found ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonFloat,
                          dst.index & 0x07, fnd.index & 0x0F]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = (the whole body contains `text`) ? 1 : 0.
    @discardableResult
    public func bodyContains(_ body: TaskJSON, _ text: String, into: TaskBoolRegister? = nil) -> TaskBoolRegister {
        rec.selectJSON(body)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extBodyContains, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, text)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = ``TaskJSONValueType`` raw value of the value at `path`.
    @discardableResult
    public func getType(_ body: TaskJSON, _ path: String, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonType, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = byte length of the value span at `path` (size before snapshotting).
    @discardableResult
    public func getSize(_ body: TaskJSON, _ path: String, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonSize, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// Navigate to the **string** value at `path`, capture its content (unquoted) into a
    /// ``TaskStringSlot``, and return a ``TaskString`` for the `board.string` ops. Slot
    /// auto-allocated (0–9) unless given; release it with `board.string.free(_:)`.
    /// (Reads the **live** body, so call it right after the `httpGet`.)
    @discardableResult
    public func getString(_ body: TaskJSON, _ path: String, into slot: TaskStringSlot? = nil) -> TaskString {
        let dst = slot ?? rec.allocateTaskStringSlot()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonGetString, dst.firmwareIndex]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return TaskString(slot: dst, rec: rec)
    }

    /// Persist the **whole current body** into a JSON snapshot slot so it survives the next
    /// request, **upgrading `body` in place** (its ``TaskJSON/snapshotSlot`` is set). Slot
    /// auto-allocated (0–1) unless given. Call right after the `httpGet` you want to keep.
    public func snapshot(_ body: TaskJSON, into slot: TaskJSONSlot? = nil) {
        let s = slot ?? rec.allocateTaskJSONSlot()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSnapshot,
                  s.firmwareIndex, 0x00, 0x00, Cmd.endSysEx])      // pathLen 0 = whole body
        body.snapshotSlot = s
    }

    /// Free the JSON snapshot slot held by `body` (if any).
    public func free(_ body: TaskJSON) {
        guard let slot = body.snapshotSlot else { return }
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extFree, slot.firmwareIndex, Cmd.endSysEx])
        body.snapshotSlot = nil
    }
}

/// Raw-string inspection of a captured string (reached via ``FirmataTaskRecorder/string``).
/// Each call takes a ``TaskString`` — from ``TaskJSONOps/getString(_:_:into:)`` or
/// ``createString(_:)`` — selects its slot on the device, then records the op.
public struct TaskStringOps {
    internal let rec: FirmataTaskRecorder

    /// Make a standalone string from a literal, stored in an auto-allocated ``TaskStringSlot``.
    /// Release it with `board.string.free(_:)`.
    @discardableResult
    public func createString(_ value: String) -> TaskString {
        let slot = rec.allocateTaskStringSlot()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringSetSlot, slot.firmwareIndex]
        rec.appendLengthPrefixed(&m, value)
        m.append(Cmd.endSysEx); rec.emit(m)
        return TaskString(slot: slot, rec: rec)
    }
    /// `R` = byte length of the string.
    @discardableResult
    public func length(_ s: TaskString, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringBodyLen, dst.index & 0x0F, Cmd.endSysEx])
        return dst
    }
    /// `R` = (string == `value`) ? 1 : 0.
    @discardableResult
    public func equals(_ s: TaskString, _ value: String, into: TaskBoolRegister? = nil) -> TaskBoolRegister {
        rec.selectString(s)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringEquals, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, value)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = (string contains `substring`) ? 1 : 0.
    @discardableResult
    public func contains(_ s: TaskString, _ substring: String, into: TaskBoolRegister? = nil) -> TaskBoolRegister {
        rec.selectString(s)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extBodyContains, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, substring)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = index of `substring` in the string, or `-1` if absent.
    @discardableResult
    public func indexOf(_ s: TaskString, _ substring: String, into: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringIndexOf, dst.index & 0x0F]
        rec.appendLengthPrefixed(&m, substring)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = the string parsed as an integer (leading sign + digits); `R[found]` = 0/1.
    @discardableResult
    public func toInt(_ s: TaskString, into: TaskNumberRegister? = nil, found: TaskNumberRegister? = nil) -> TaskNumberRegister {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        let fnd = found ?? rec.allocateRegister()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringToNum,
                  dst.index & 0x0F, fnd.index & 0x0F, Cmd.endSysEx])
        return dst
    }
    /// Free the device slot held by a string handle.
    public func free(_ s: TaskString) {
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extFree, s.slot.firmwareIndex, Cmd.endSysEx])
    }
}

/// A typed value the device evaluates in ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``
/// and arithmetic — an integer/float register or a literal. (Non-standard extension.)
/// When either side of a comparison/op is a float, the device promotes to float.
///
/// This is the root protocol; the recorder's ops hand back the concrete kind that
/// matches what they produce — ``TaskNumber``, ``TaskFloat``, or ``TaskBool`` —
/// so the static type tells you what a value *is*. Build literals with
/// ``number(_:)`` / ``float(_:)`` / ``bool(_:)``, and name registers explicitly with
/// ``reg(_:)`` / ``freg(_:)``.
public protocol TaskOperand: Sendable {
    /// Wire encoding: `00 reg` | `01 const:5` | `02 freg` | `03 fconst:5`.
    var operandBytes: [UInt8] { get }
}

public protocol TaskRegister: TaskOperand {
    var index: UInt8 { get }
}

public protocol TaskLiteral: TaskOperand {
}

extension TaskOperand {
    public var index: UInt8? {
        guard let registerOperand = self as? TaskRegister else { return nil }
        // `as UInt8` pins lookup to TaskRegister's non-optional `register`;
        // without it the expression resolves back to this optional property and recurses.
        return registerOperand.index as UInt8
    }
}

public extension TaskOperand where Self == TaskNumberLiteral {
    /// A fixed signed 32-bit integer literal.
    static func number(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == TaskNumberRegister {
    /// One of the device's 16 integer registers, by index (`0`–`15`).
    static func reg(_ r: UInt8) -> Self {
        .init(index: r)
    }
}

public extension TaskOperand where Self == TaskFloatLiteral {
    /// A fixed `Float` literal.
    static func float(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == TaskFloatRegister {
    /// One of the device's 8 float registers, by index (`0`–`7`).
    static func freg(_ r: UInt8) -> Self {
        .init(index: r)
    }
}

public extension TaskOperand where Self == TaskBoolLiteral {
    /// A fixed boolean literal (`1`/`0`, compared as an integer).
    static func bool(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == TaskBoolRegister {
    /// An integer register reinterpreted as a boolean (`0`/non-zero) result.
    static func boolReg(_ r: UInt8) -> Self {
        .init(index: r)
    }
}

/// An integer-valued operand — either ``TaskNumberLiteral`` or ``TaskNumberRegister``.
public protocol TaskNumber: TaskOperand {
}

/// An integer-valued literal operand. Make a compile-time constant with
/// ``TaskOperand/number(_:)`` or `TaskNumberLiteral(rawValue: 200)`.
public struct TaskNumberLiteral: RawRepresentable, TaskLiteral, TaskNumber {
    public var rawValue: Int32

    /// A compile-time signed 32-bit constant.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [1] + encode7BitFirmata(timeBytes(UInt32(bitPattern: rawValue)))
    }
}

public struct TaskNumberRegister: TaskRegister, TaskNumber {
    public var index: UInt8

    public init(index: UInt8) {
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [0, index & 0x0F]
    }
}

/// A floating-point operand — either ``TaskFloatLiteral`` or ``TaskFloatRegister``.
public protocol TaskFloat: TaskOperand {
}

/// A floating-point literal operand. Make a compile-time constant with
/// ``TaskOperand/float(_:)`` or `TaskFloatLiteral(rawValue: 1.5)`.
public struct TaskFloatLiteral: RawRepresentable, TaskLiteral, TaskFloat {
    public var rawValue: Float

    /// A compile-time `Float` constant.
    public init(rawValue: Float) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [3] + encode7BitFirmata(timeBytes(rawValue.bitPattern))
    }
}

public struct TaskFloatRegister: TaskRegister, TaskFloat {
    public var index: UInt8

    public init(index: UInt8) {
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [2, index & 0x07]
    }
}

/// A boolean-valued operand — either ``TaskBoolLiteral`` or ``TaskBoolRegister``.
/// Produced by the predicate ops (``FirmataTaskRecorder``'s `string.equals`,
/// `bodyContains`, `digitalRead(pin:)`, …) and consumable directly by `ifTrue`.
public protocol TaskBool: TaskOperand {
}

/// A boolean literal operand, backed by a `0`/`1` integer compared as an integer.
public struct TaskBoolLiteral: RawRepresentable, TaskLiteral, TaskBool {
    public var rawValue: Bool

    /// A compile-time boolean constant.
    public init(rawValue: Bool) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [1] + encode7BitFirmata(timeBytes(UInt32(rawValue ? 1 : 0)))
    }
}

public struct TaskBoolRegister: TaskRegister, TaskBool {
    public var index: UInt8

    public init(index: UInt8) {
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [0, index & 0x0F]
    }
}

public extension TaskBoolRegister {
    /// Reinterpret an integer register as a boolean (`0`/non-zero) operand. Both kinds
    /// name the same `R[n]` in the device's 16 Int32 registers, so this is a pure rename.
    init(_ numberRegister: TaskNumberRegister) {
        self.init(index: numberRegister.index)
    }
}

/// One of the device's **JSON snapshot slots** (`0`–`1`) — a typed slot, like a register operand.
public struct TaskJSONSlot: Sendable {
    public let index: UInt8
    public init(_ index: UInt8) { self.index = index }
    internal var firmwareIndex: UInt8 { index & 0x01 }            // device snapshot pool: 0–1
}

/// One of the device's **string slots** (`0`–`9`) — a typed slot, like a register operand.
public struct TaskStringSlot: Sendable {
    public let index: UInt8
    public init(_ index: UInt8) { self.index = index }
    internal var firmwareIndex: UInt8 { (index % 10) + 2 }        // device snapshot pool: 2–11 (after the 2 JSON slots)
}

/// A handle to a **JSON response body** — reach it via ``TaskHTTPResponse/body`` and pass it
/// to the `board.json` inspection ops. A *borrowed* handle reads the device's live body,
/// checked for staleness against the generation captured at request time (a later request
/// makes it stale — test it with ``isValid()``). ``TaskJSONOps/snapshot(_:into:)``
/// upgrades it **in place** to an owned copy in a ``TaskJSONSlot`` that survives later requests.
public final class TaskJSON: @unchecked Sendable {
    /// Register holding the body generation captured at request time (borrowed handle).
    internal let genReg: TaskNumberRegister
    /// Slot once snapshotted into an owned, persisted copy (`nil` = borrowed/live).
    internal var snapshotSlot: TaskJSONSlot?
    /// The recorder that produced this handle (so ``isValid()`` can record into the task).
    internal weak var rec: FirmataTaskRecorder?

    internal init(genReg: TaskNumberRegister, snapshotSlot: TaskJSONSlot?, rec: FirmataTaskRecorder?) {
        self.genReg = genReg; self.snapshotSlot = snapshotSlot; self.rec = rec
    }

    /// Record a boolean that is `true` while the captured live body is still the current one.
    /// After a newer request replaces it this reads `false`; an owned snapshot is always valid.
    @discardableResult
    public func isValid() -> TaskBool {
        guard snapshotSlot == nil, let rec else { return .bool(true) }
        return rec.compare(genReg, .equal, rec.currentRequestCount())
    }
}

/// A captured string living in a ``TaskStringSlot`` — from ``TaskJSONOps/getString(_:_:into:)`` or
/// ``TaskStringOps/createString(_:)`` — inspected with the `board.string` ops.
public final class TaskString: @unchecked Sendable {
    /// The string slot this handle currently occupies.
    public internal(set) var slot: TaskStringSlot
    internal weak var rec: FirmataTaskRecorder?

    internal init(slot: TaskStringSlot, rec: FirmataTaskRecorder?) {
        self.slot = slot; self.rec = rec
    }

    /// Copy this string's contents into `slot` on the device, then rebind this handle to it.
    public func changeSlot(_ slot: TaskStringSlot) {
        guard let rec else { return }
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringCopySlot,
                  slot.firmwareIndex, self.slot.firmwareIndex, Cmd.endSysEx])
        self.slot = slot
    }
}

/// A handle to an internet request recorded in a task — returned by
/// ``FirmataTaskRecorder/httpGet(_:statusInto:)`` / ``httpPost(_:body:statusInto:)``.
/// Branch on ``status``; inspect the payload as JSON via ``body`` (`board.json`), and
/// navigate to a string value with `board.json.getString(body, …)` for the `board.string` ops.
public struct TaskHTTPResponse: Sendable {
    /// Operand for the register holding the HTTP status code (`0` on failure).
    public let status: TaskNumberRegister
    /// Handle to the response body for the `board.json` inspection ops. Navigate to a
    /// string value with `board.json.getString(body, "path")` to get a ``TaskString``
    /// for the `board.string` ops.
    public let body: TaskJSON
}

/// Result-status codes the device records for an inspection op (matches the firmware's
/// `ST_*` values). Staleness of a borrowed body handle is surfaced on the host via
/// ``TaskJSON/isValid()``.
public enum TaskResultStatus: Int32, Sendable {
    case ok = 0, notFound = 1, stale = 2, typeMismatch = 3, tooBig = 4, allocFailed = 5
}

/// JSON value kinds returned by ``FirmataTaskRecorder/jsonType(_:into:)``.
/// Compare a `jsonType` result against `.number.rawValue` etc. via `.const`.
public enum TaskJSONValueType: Int32, Sendable {
    case missing = 0, object = 1, array = 2, string = 3, number = 4, bool = 5, null = 6
}

/// A comparison for ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``.
/// (Non-standard extension.)
public enum TaskComparison: UInt8, Sendable {
    case equal          = 0
    case notEqual       = 1
    case lessThan       = 2
    case greaterThan    = 3
    case lessOrEqual    = 4
    case greaterOrEqual = 5
}

// MARK: - Internet-action op encoding (non-standard extension)

/// Encode a `SCHED_EXT_HTTP` op (used both inside tasks and for live requests).
/// Layout: `F0 7B 7F 15 method statusReg urlLo urlHi url[…] bodyLo bodyHi body[…] F7`.
/// URL/body are sent as raw 7-bit ASCII; lengths are 14-bit little-endian. The
/// response body is retained on the device for the inspection ops.
internal func httpOpBytes(method: UInt8, statusReg: TaskNumberRegister, url: String, body: String?) -> [UInt8] {
    let u = Array(url.utf8)
    let b = Array((body ?? "").utf8)
    var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHttp,
                      method, statusReg.index & 0x0F]
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
internal func encode7BitFirmata(_ data: [UInt8]) -> [UInt8] {
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
internal func decode7BitFirmata(_ outBytes: Int, _ input: [UInt8]) -> [UInt8] {
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
internal func num7BitOutBytes(_ encodedLen: Int) -> Int { (encodedLen * 7) / 8 }

/// Little-endian 4-byte representation of a 32-bit value (for time fields).
internal func timeBytes(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF),
     UInt8((value >> 8) & 0xFF),
     UInt8((value >> 16) & 0xFF),
     UInt8((value >> 24) & 0xFF)]
}
