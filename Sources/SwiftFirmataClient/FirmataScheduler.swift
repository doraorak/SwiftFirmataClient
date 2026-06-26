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
/// try await client.uploadTask(id: 1) { board in
/// //                                  ^ this is the recorder
///     board.setPinMode(2, mode: .output)
///     board.digitalWrite(pin: 2, high: true)
/// }
/// ```
///
/// **What is `board in`?** It's just Swift closure syntax: `{ board in … }` declares a
/// closure whose one parameter is named `t`. Here that parameter *is* the
/// `FirmataTaskRecorder`, so inside the braces you call `board.setPinMode(…)`,
/// `board.digitalWrite(…)`, `board.delay(…)`, etc. to record each step. The name `board` is
/// arbitrary — `{ recorder in … }` or the shorthand `{ $0.digitalWrite(…) }` mean
/// the same thing. (`inout` lets your calls mutate the recorder in place.)
///
/// The methods mirror the live ``FirmataClient`` calls but **capture the bytes
/// instead of sending them** — so they're synchronous (no `await`). Insert
/// ``delay(ms:)`` between actions to make the device wait while the task runs.
public final class FirmataTaskRecorder {
    /// The recorded bytes so far (the task program). Usually you don't touch this
    /// directly — `uploadTask` reads it for you.
    public private(set) var bytes: [UInt8] = []

    /// Next register handed out by ``digitalRead(pin:)`` / ``analogRead(channel:)``
    /// (descends `R15 → R0`, then wraps).
    private var nextAutoRegister: NumberRegisterOperand = .reg(15)
    /// Next float register auto-allocated for `jsonFloat` / float arithmetic
    /// (descends `F7 → F0`, then wraps).
    private var nextAutoFloatRegister: FloatRegisterOperand = .freg(7)
    /// Next snapshot slot auto-allocated by ``snapshot(_:into:)`` (0–1, then wraps).
    private var nextSnapshotSlot: UInt8 = 0
    /// Generation registers (for handle staleness) allocate bottom-up (R0↑) so they
    /// don't collide with the top-down (R15↓) pool used by reads/arithmetic results.
    private var nextRequestCountRegister: NumberRegisterOperand = .reg(0)

    public init() {}

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
    /// (which is what ``FirmataClient/uploadTask(id:startDelayMs:repeatEveryMs:_:)``'s
    /// `repeatEveryMs` adds for you).
    /// - Parameter ms: How long to wait, in milliseconds.
    public func delay(ms: UInt32) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.delay]
        bytes += encode7BitFirmata(timeBytes(ms))
        bytes.append(Cmd.endSysEx)
    }

    // MARK: I2C (standard Firmata — drive an I2C device from a task)
    //
    // The scheduler replays these through the device's Firmata parser, so a task
    // can talk to an I2C peripheral (e.g. write command/data bytes to an SSD1306
    // OLED) with no host connected. Call `i2cConfig` once (it begins the bus),
    // then `i2cWrite` as needed. (Reads aren't offered here — their reply has no
    // host to receive it inside an autonomous task.)

    /// Record an I2C bus config/begin (`delayMicroseconds` between register-write
    /// and read). Do this once at the start of a task that uses I2C.
    public func i2cConfig(delayMicroseconds: UInt16 = 0) {
        bytes += [Cmd.startSysEx, SysEx.i2cConfig,
                  UInt8(delayMicroseconds & 0x7F), UInt8((delayMicroseconds >> 7) & 0x7F),
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
    public func setRegister(_ dst: NumberRegisterOperand, to value: NumberLiteralOperand.RawValue) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSet, dst.register & 0x0F]
        bytes += encode7BitFirmata(timeBytes(UInt32(bitPattern: value)))
        bytes.append(Cmd.endSysEx)
    }

    /// Record `register = digitalRead(pin)` (stores `0`/`1`). The pin should be an
    /// input — record `setPinMode(pin, mode: .input)` earlier in the task.
    /// - Parameters:
    ///   - register: Destination register, `0`–`15`.
    ///   - pin: The board pin to read.
    public func digitalRead(into register: BoolRegisterOperand, pin: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extDigitalRead,
                  register.register & 0x0F, pin & 0x7F, Cmd.endSysEx]
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
    public func analogRead(into register: NumberRegisterOperand, channel: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extAnalogRead,
                  register.register & 0x0F, channel & 0x0F, Cmd.endSysEx]
    }

    /// Record `digitalRead(pin)` into an **auto-allocated** register and return that
    /// register as a ``TaskOperand`` — so you can drop the read straight into a
    /// comparison. (A recorder can't return a live value; the read happens on the
    /// device when the task runs, and this hands you the register it lands in.)
    ///
    /// ```swift
    /// let pressed = t.digitalRead(pin: 7)              // -> .reg(n)
    /// t.ifTrue(pressed, .equal, .number(0),             // active-low button
    ///     then: { $0.digitalWrite(pin: 2, high: true) })
    /// ```
    ///
    /// Auto-allocated registers cycle `R15 → R0`; for explicit control use
    /// ``digitalRead(into:pin:)``. Read into a local first if you'll reuse it, since
    /// a later auto-read may reuse the same register.
    /// - Parameter pin: The board pin to read (put it in `.input`/`.inputPullup` first).
    /// - Returns: The register operand holding `0`/`1`.
    public func digitalRead(pin: UInt8) -> BoolRegisterOperand {
        let r = BoolRegisterOperand(allocateRegister())
        digitalRead(into: r, pin: pin)
        return r
    }

    /// Record `analogRead(channel)` into an **auto-allocated** register and return
    /// that register as a ``TaskOperand`` for use in
    /// ``ifTrue(_:_:_:then:elseDo:)``. See ``digitalRead(pin:)`` for the allocation
    /// rules; use ``analogRead(into:channel:)`` to choose the register yourself.
    /// - Parameter channel: Analog channel index (`A0 = 0`, …), **not** a pin number.
    /// - Returns: The register operand holding the reading.
    public func analogRead(channel: UInt8) -> NumberRegisterOperand {
        let r = allocateRegister(); analogRead(into: r, channel: channel); return r
    }

    /// Hand out the next auto-allocated register, descending `R15 → R0` then wrapping
    /// (kept high to avoid clashing with low registers you set explicitly).
    private func allocateRegister() -> NumberRegisterOperand {
        let r = nextAutoRegister
        let raw = r.register
        nextAutoRegister = .reg((raw == 0) ? 15 : (raw - 1))
        return r
    }

    private func allocateFloatRegister() -> FloatRegisterOperand {
        let r = nextAutoFloatRegister
        let raw = r.register
        nextAutoFloatRegister = .freg((raw == 0) ? 7 : (raw - 1))
        return r
    }

    private func allocateSnapshotSlot() -> UInt8 {
        let s = nextSnapshotSlot
        nextSnapshotSlot = (nextSnapshotSlot == 1) ? 0 : (nextSnapshotSlot + 1)
        return s
    }

    private func allocateGenRegister() -> NumberRegisterOperand {
        let r = nextRequestCountRegister
        let raw = r.register
        nextRequestCountRegister = .reg((raw == 15) ? 0 : (raw + 1))
        return r
    }

    /// Record an `if` (optionally with `else`) that the **device** evaluates while
    /// the task runs. It compares the two operands with `op`; the `then` block runs
    /// only when the comparison is true, otherwise the `elseDo` block (if given) runs.
    ///
    /// ```swift
    /// t.analogRead(into: .reg(0), channel: 0)              // R0 = analog A0
    /// t.ifTrue(.reg(0), .greaterThan, .number(512),         // if R0 > 512
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

    /// Record an `if` driven by a **boolean operand** — the `then` block runs when
    /// `condition` is true (non-zero), otherwise `elseDo` (if given). Pass a value from
    /// any predicate op: ``digitalRead(pin:)``, `json.stringEquals`, `bodyContains`,
    /// ``compare(_:_:_:into:)``, etc.
    ///
    /// ```swift
    /// let pressed = t.digitalRead(pin: 7)        // -> BoolOperand
    /// t.ifTrue(pressed) { $0.digitalWrite(pin: 2, high: true) }
    /// ```
    ///
    /// This is shorthand for ``ifTrue(_:_:_:then:elseDo:)`` with `.notEqual, .number(0)`.
    /// - Parameters:
    ///   - condition: A boolean operand (a `0`/non-zero register or literal).
    ///   - then: Steps to run when `condition` is true.
    ///   - elseDo: Optional steps to run when `condition` is false.
    public func ifTrue(
        _ condition: BoolOperand,
        then: (inout FirmataTaskRecorder) -> Void,
        elseDo: ((inout FirmataTaskRecorder) -> Void)? = nil
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
    /// let isUp = board.compare(pct, .greaterThan, .number(0))   // -> BoolOperand
    /// board.ifTrue(isUp) { $0.digitalWrite(pin: 2, high: true) }
    /// ```
    @discardableResult
    public func compare(_ a: TaskOperand, _ op: TaskComparison, _ b: TaskOperand,
                        into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        let dst = into ?? BoolRegisterOperand(allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extCmp,
                          op.rawValue, dst.register & 0x0F]
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
    /// (`board.json.number(resp.body, …)`, `.float`, `.stringEquals`, …) — then branch
    /// with `ifTrue`:
    ///
    /// ```swift
    /// // Green/red LED from SPY's % change, no host connected.
    /// try await client.uploadTask(id: 5, repeatEveryMs: 60_000) { board in
    ///     board.setPinMode(2, mode: .output); board.setPinMode(4, mode: .output)
    ///     let spy = board.httpGet("https://example.com/quote/SPY")             // -> TaskHTTPResponse
    ///     let pct = board.json.number(spy.body, "changePercent", scaledBy: 2)  // -0.42% -> -42
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
    ///   ``json`` ops (`board.json.number(resp.body, …)`) to inspect the payload.
    @discardableResult
    public func httpGet(_ url: String, statusInto: NumberRegisterOperand? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 0, statusReg: statusReg, url: url, body: nil)
        return makeResponse(statusReg: statusReg)
    }

    /// Record an **internet `POST`** (Wi-Fi, `Content-Type: application/json`).
    /// Returns a ``TaskHTTPResponse`` (status auto-allocated unless `statusInto:` is given);
    /// inspect the body with the JSON/string ops.
    @discardableResult
    public func httpPost(_ url: String, body: String, statusInto: NumberRegisterOperand? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 1, statusReg: statusReg, url: url, body: body)
        return makeResponse(statusReg: statusReg)
    }

    // Capture the body generation into a register so the body handle can be staleness-checked.
    private func makeResponse(statusReg: NumberRegisterOperand) -> TaskHTTPResponse {
        let gReg = allocateGenRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, gReg.register & 0x0F, Cmd.endSysEx]
        return TaskHTTPResponse(status: statusReg,
                                body: JSONHandle(genReg: gReg, snapshotSlot: nil, rec: self))
    }

    // MARK: Body handles — snapshot / select / free

    /// Persist the **whole current body** into a snapshot slot so it survives the next
    /// request, **upgrading `body` in place** to an owned handle (its ``JSONHandle/snapshotSlot``
    /// is set). Slot auto-allocated (0–1) unless given. Call right after the `httpGet` whose
    /// body you want to keep; subsequent `board.json` ops on the same handle read the snapshot.
    func snapshot(_ body: some ResponseBodyHandle, into slot: UInt8? = nil) {
        let s = slot ?? allocateSnapshotSlot()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSnapshot,
                  s & 0x01, 0x00, 0x00, Cmd.endSysEx]      // pathLen 0 = whole body
        body.snapshotSlot = s & 0x01
    }

    /// Choose which body the following inspection ops read: a snapshot (owned), or the
    /// live body checked against this handle's generation (a borrowed handle used after a
    /// newer request reads as **stale** — test it with ``JSONHandle/isValid()``).
    func select(_ body: some ResponseBodyHandle) {
        if let slot = body.snapshotSlot {
            bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                      (slot & 0x01) + 1, 0x00, Cmd.endSysEx]
        } else {
            bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                      0x00, body.genReg.register & 0x0F, Cmd.endSysEx]
        }
    }

    /// Free a snapshot slot held by an owned body handle.
    func free(_ body: some ResponseBodyHandle) {
        guard let slot = body.snapshotSlot else { return }
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extFree, slot & 0x01, Cmd.endSysEx]
    }

    /// Read the device's current request count (body generation) into a register.
    /// Used by ``JSONHandle/isValid()`` to compare against a handle's captured generation.
    func currentRequestCount(into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, dst.register & 0x0F, Cmd.endSysEx]
        return dst
    }

    // MARK: Response inspection (operate on the last httpGet/httpPost body)

    /// Record reading a **number from the last response's JSON** at `path` into a
    /// register, scaled by `10^scaledBy` and truncated (so fractions survive in the
    /// Int32 register — `changePercent -0.42` with `scaledBy: 2` → `-42`). Returns
    /// the value register as a ``TaskOperand`` for `ifTrue`.
    ///
    /// `path` is dotted with array indices, e.g. `quoteResponse.result[0].regularMarketChangePercent`.
    /// - Parameters:
    ///   - path: JSON path (ASCII).
    ///   - scaledBy: Decimal places to keep (`0` = integer part only).
    ///   - into: Value register; auto-allocated (R15↓) if omitted.
    ///   - found: Register set to `1` if the path resolved to a number, else `0`; auto-allocated if omitted.
    /// - Returns: The value register operand.
    @discardableResult
    func jsonNumber(_ path: String, scaledBy: UInt8 = 0,
                                    into: NumberRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        let fnd = found ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonNum,
                          dst.register & 0x0F, fnd.register & 0x0F, scaledBy]
        appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record testing whether the whole last response body **contains** `text`
    /// (raw substring). Returns the `0/1` result register.
    @discardableResult
    func bodyContains(_ text: String, into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        let dst = into ?? BoolRegisterOperand(allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extBodyContains, dst.register & 0x0F]
        appendLengthPrefixed(&m, text)
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record copying the **content** (unquoted) of the JSON string at `path` from the
    /// live body into snapshot `slot` (auto-allocated if nil). Returns the slot used.
    /// Backs ``JSONOps/getString(_:_:into:)``.
    func jsonGetString(_ path: String, into slot: UInt8? = nil) -> UInt8 {
        let s = slot ?? allocateSnapshotSlot()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonGetString, s & 0x01]
        appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); bytes += m
        return s & 0x01
    }

    // MARK: Raw-string ops over the selected body (board.string)

    @discardableResult
    func strBodyLength(into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStrBodyLen, dst.register & 0x0F, Cmd.endSysEx]
        return dst
    }
    @discardableResult
    func strEquals(_ value: String, into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        let dst = into ?? BoolRegisterOperand(allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStrEquals, dst.register & 0x0F]
        appendLengthPrefixed(&m, value); m.append(Cmd.endSysEx); bytes += m
        return dst
    }
    @discardableResult
    func strIndexOf(_ sub: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStrIndexOf, dst.register & 0x0F]
        appendLengthPrefixed(&m, sub); m.append(Cmd.endSysEx); bytes += m
        return dst
    }
    @discardableResult
    func strToNum(into: NumberRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        let fnd = found ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStrToNum,
                  dst.register & 0x0F, fnd.register & 0x0F, Cmd.endSysEx]
        return dst
    }

    private func appendLengthPrefixed(_ m: inout [UInt8], _ s: String) {
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
    public func add(_ a: TaskOperand, _ b: TaskOperand, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        arith(0, a, b, into)
    }
    /// Record `R[dst] = a - b`. See ``add(_:_:into:)``.
    @discardableResult
    public func subtract(_ a: TaskOperand, _ b: TaskOperand, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        arith(1, a, b, into)
    }
    /// Record `R[dst] = a * b`. See ``add(_:_:into:)``.
    @discardableResult
    public func multiply(_ a: TaskOperand, _ b: TaskOperand, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        arith(2, a, b, into)
    }
    /// Record `R[dst] = a / b` (integer division; `÷0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func divide(_ a: TaskOperand, _ b: TaskOperand, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        arith(3, a, b, into)
    }
    /// Record `R[dst] = a % b` (`%0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func modulo(_ a: TaskOperand, _ b: TaskOperand, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        arith(4, a, b, into)
    }

    private func arith(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                _ into: NumberRegisterOperand?) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArith, sub, dst.register & 0x0F]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    // MARK: Float registers (8 of them, F0–F7)

    /// Record `F[dst] = value`. Returns the float register as a `.freg` operand.
    @discardableResult
    public func setFloatRegister(_ dst: FloatRegisterOperand, to value: FloatLiteralOperand.RawValue) -> FloatRegisterOperand {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSetFloat, dst.register & 0x07]
        m += encode7BitFirmata(timeBytes(value.bitPattern))
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record reading a **float** from the last response's JSON at `path` into a
    /// float register (handles unquoted `593.2`, quoted `"593.2"`, and exponents).
    /// Returns the float register operand; `found` (int reg) is `1`/`0`.
    @discardableResult
    func jsonFloat(_ path: String, into: FloatRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> FloatRegisterOperand {
        let dst = into ?? allocateFloatRegister()
        let fnd = found ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonFloat,
                          dst.register & 0x07, fnd.register & 0x0F]
        appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record `F[dst] = a + b` (float). Operands may be float/int registers or
    /// literals (ints promote to float). Result float register auto-allocated
    /// (F7↓) unless `into:` is given. `÷0` → 0.
    @discardableResult
    public func addFloat(_ a: TaskOperand, _ b: TaskOperand, into: FloatRegisterOperand? = nil) -> FloatRegisterOperand {
        arithF(0, a, b, into)
    }
    /// Record `F[dst] = a - b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func subtractFloat(_ a: TaskOperand, _ b: TaskOperand, into: FloatRegisterOperand? = nil) -> FloatRegisterOperand {
        arithF(1, a, b, into)
    }
    /// Record `F[dst] = a * b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func multiplyFloat(_ a: TaskOperand, _ b: TaskOperand, into: FloatRegisterOperand? = nil) -> FloatRegisterOperand {
        arithF(2, a, b, into)
    }
    /// Record `F[dst] = a / b` (float; `÷0` → 0). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func divideFloat(_ a: TaskOperand, _ b: TaskOperand, into: FloatRegisterOperand? = nil) -> FloatRegisterOperand {
        arithF(3, a, b, into)
    }

    private func arithF(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                 _ into: FloatRegisterOperand?) -> FloatRegisterOperand {
        let dst = into ?? allocateFloatRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArithFloat, sub, dst.register & 0x07]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    // MARK: Query the last response (inspect before you extract / store)

    /// Record `R[dst]` = the ``TaskJSONValueType`` of the value at `path` (its raw value).
    /// Branch with `ifTrue(t, .equal, .number(TaskJSONValueType.number.rawValue))`.
    @discardableResult
    func jsonType(_ path: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        queryOp(Sched.extJsonType, path, into)
    }
    /// Record `R[dst]` = byte length of the value's span at `path` (`0` if missing) —
    /// size a snapshot before storing it.
    @discardableResult
    func jsonSize(_ path: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        queryOp(Sched.extJsonSize, path, into)
    }
    private func queryOp(_ op: UInt8, _ path: String, _ into: NumberRegisterOperand?) -> NumberRegisterOperand {
        let dst = into ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, op, dst.register & 0x0F]
        appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record reading heap stats into registers — `free` heap and `largest`
    /// contiguous block — so a task can gate an allocation on available memory.
    @discardableResult
    public func heapStats(freeInto: NumberRegisterOperand? = nil,
                                   largestInto: NumberRegisterOperand? = nil) -> (free: NumberRegisterOperand, largest: NumberRegisterOperand) {
        let f = freeInto ?? allocateRegister()
        let l = largestInto ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHeap,
                  f.register & 0x0F, l.register & 0x0F, Cmd.endSysEx]
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
    /// `board.json.number(resp.body, "path")`. (A tiny value-type view over the recorder;
    /// no instance to manage.)
    public var json: JSONOps { JSONOps(rec: self) }

    /// Raw-string inspection of a recorded response body — `board.string` ops over a
    /// ``StringHandle`` from ``JSONOps/getString(_:_:into:)``.
    public var string: StringOps { StringOps(rec: self) }
}

/// JSON inspection of a recorded response body (reached via ``FirmataTaskRecorder/json``).
/// Each call takes a ``JSONHandle`` body handle (from ``TaskHTTPResponse/body`` or
/// ``snapshot(_:into:)``): it selects that source on the device — a snapshot, or the live
/// body checked for staleness against the handle's generation — then records the op. Branch
/// on results with `board.ifTrue`, and guard a borrowed handle's freshness with
/// ``JSONHandle/isValid()``.
public struct JSONOps {
    let rec: FirmataTaskRecorder

    /// `R` = number at `path` × 10^`scaledBy` (truncated; also parses quoted numbers).
    @discardableResult
    public func number(_ body: JSONHandle, _ path: String, scaledBy: UInt8 = 0,
                       into: NumberRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(body); return rec.jsonNumber(path, scaledBy: scaledBy, into: into, found: found)
    }
    /// `F` = floating-point number at `path` (handles quoted / fractional / exponent).
    @discardableResult
    public func float(_ body: JSONHandle, _ path: String,
                      into: FloatRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> FloatRegisterOperand {
        rec.select(body); return rec.jsonFloat(path, into: into, found: found)
    }
    /// `R` = (the whole body contains `text`) ? 1 : 0.
    @discardableResult
    public func bodyContains(_ body: JSONHandle, _ text: String, into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        rec.select(body); return rec.bodyContains(text, into: into)
    }
    /// `R` = ``TaskJSONValueType`` raw value of the value at `path`.
    @discardableResult
    public func type(_ body: JSONHandle, _ path: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(body); return rec.jsonType(path, into: into)
    }
    /// `R` = byte length of the value span at `path` (size before snapshotting).
    @discardableResult
    public func size(_ body: JSONHandle, _ path: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(body); return rec.jsonSize(path, into: into)
    }
    /// Navigate to the **string** value at `path` and capture its content (unquoted) into a
    /// snapshot slot, returning a ``StringHandle`` for the `board.string` ops. Slot
    /// auto-allocated (0–1) unless given; release it with `board.string.free(_:)`.
    /// (Reads the **live** body, so call it right after the `httpGet`.)
    @discardableResult
    public func getString(_ body: JSONHandle, _ path: String, into slot: UInt8? = nil) -> StringHandle {
        let s = rec.jsonGetString(path, into: slot)
        return StringHandle(genReg: body.genReg, snapshotSlot: s, rec: rec)
    }
    /// Persist the body into a slot that survives the next request, **upgrading `body` in
    /// place** to an owned handle — call right after the `httpGet` you want to keep.
    public func snapshot(_ body: JSONHandle, into slot: UInt8? = nil) { rec.snapshot(body, into: slot) }
    /// Free a snapshot slot held by an owned body handle.
    public func free(_ body: JSONHandle) { rec.free(body) }
}

/// Raw-string inspection of a recorded response body (reached via ``FirmataTaskRecorder/string``).
/// Each call takes a ``StringHandle`` from ``JSONOps/getString(_:_:into:)``: it selects that
/// captured string on the device, then records the op. Branch on results with `board.ifTrue`.
public struct StringOps {
    let rec: FirmataTaskRecorder

    /// `R` = byte length of the whole string.
    @discardableResult
    public func length(_ s: StringHandle, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(s); return rec.strBodyLength(into: into)
    }
    /// `R` = (string == `value`) ? 1 : 0.
    @discardableResult
    public func equals(_ s: StringHandle, _ value: String, into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        rec.select(s); return rec.strEquals(value, into: into)
    }
    /// `R` = (string contains `substring`) ? 1 : 0.
    @discardableResult
    public func contains(_ s: StringHandle, _ substring: String, into: BoolRegisterOperand? = nil) -> BoolRegisterOperand {
        rec.select(s); return rec.bodyContains(substring, into: into)
    }
    /// `R` = index of `substring` in the string, or `-1` if absent.
    @discardableResult
    public func indexOf(_ s: StringHandle, _ substring: String, into: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(s); return rec.strIndexOf(substring, into: into)
    }
    /// `R` = the string parsed as an integer (leading sign + digits); `R[found]` = 0/1.
    @discardableResult
    public func toInt(_ s: StringHandle, into: NumberRegisterOperand? = nil, found: NumberRegisterOperand? = nil) -> NumberRegisterOperand {
        rec.select(s); return rec.strToNum(into: into, found: found)
    }
    /// Persist the body into a slot that survives the next request, upgrading `s` in place.
    public func snapshot(_ s: StringHandle, into slot: UInt8? = nil) { rec.snapshot(s, into: slot) }
    /// Free a snapshot slot held by an owned handle.
    public func free(_ s: StringHandle) { rec.free(s) }
}

/// A typed value the device evaluates in ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``
/// and arithmetic — an integer/float register or a literal. (Non-standard extension.)
/// When either side of a comparison/op is a float, the device promotes to float.
///
/// This is the root protocol; the recorder's ops hand back the concrete kind that
/// matches what they produce — ``NumberOperand``, ``FloatOperand``, or ``BoolOperand`` —
/// so the static type tells you what a value *is*. Build literals with
/// ``number(_:)`` / ``float(_:)`` / ``bool(_:)``, and name registers explicitly with
/// ``reg(_:)`` / ``freg(_:)``.
public protocol TaskOperand: Sendable {
    /// Wire encoding: `00 reg` | `01 const:5` | `02 freg` | `03 fconst:5`.
    var operandBytes: [UInt8] { get }
}

public protocol TaskRegisterOperand: TaskOperand {
    var register: UInt8 { get }
}

public protocol TaskLiteralOperand: TaskOperand {
}

extension TaskOperand {
    public var register: UInt8? {
        guard let registerOperand = self as? TaskRegisterOperand else { return nil }
        // `as UInt8` pins lookup to TaskRegisterOperand's non-optional `register`;
        // without it the expression resolves back to this optional property and recurses.
        return registerOperand.register as UInt8
    }
}

public extension TaskOperand where Self == NumberLiteralOperand {
    /// A fixed signed 32-bit integer literal.
    static func number(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == NumberRegisterOperand {
    /// One of the device's 16 integer registers, by index (`0`–`15`).
    static func reg(_ r: UInt8) -> Self {
        .init(register: r)
    }
}

public extension TaskOperand where Self == FloatLiteralOperand {
    /// A fixed `Float` literal.
    static func float(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == FloatRegisterOperand {
    /// One of the device's 8 float registers, by index (`0`–`7`).
    static func freg(_ r: UInt8) -> Self {
        .init(register: r)
    }
}

public extension TaskOperand where Self == BoolLiteralOperand {
    /// A fixed boolean literal (`1`/`0`, compared as an integer).
    static func bool(_ value: Self.RawValue) -> Self {
        .init(rawValue: value)
    }
}
public extension TaskOperand where Self == BoolRegisterOperand {
    /// An integer register reinterpreted as a boolean (`0`/non-zero) result.
    static func boolReg(_ r: UInt8) -> Self {
        .init(register: r)
    }
}

/// An integer-valued operand — either ``NumberLiteralOperand`` or ``NumberRegisterOperand``.
public protocol NumberOperand: TaskOperand {
}

/// An integer-valued literal operand. Make a compile-time constant with
/// ``TaskOperand/number(_:)`` or `NumberLiteralOperand(rawValue: 200)`.
public struct NumberLiteralOperand: RawRepresentable, TaskLiteralOperand, NumberOperand {
    public var rawValue: Int32

    /// A compile-time signed 32-bit constant.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [1] + encode7BitFirmata(timeBytes(UInt32(bitPattern: rawValue)))
    }
}

public struct NumberRegisterOperand: TaskRegisterOperand, NumberOperand {
    public var register: UInt8

    public init(register: UInt8) {
        self.register = register
    }

    public var operandBytes: [UInt8] {
        [0, register & 0x0F]
    }
}

/// A floating-point operand — either ``FloatLiteralOperand`` or ``FloatRegisterOperand``.
public protocol FloatOperand: TaskOperand {
}

/// A floating-point literal operand. Make a compile-time constant with
/// ``TaskOperand/float(_:)`` or `FloatLiteralOperand(rawValue: 1.5)`.
public struct FloatLiteralOperand: RawRepresentable, TaskLiteralOperand, FloatOperand {
    public var rawValue: Float

    /// A compile-time `Float` constant.
    public init(rawValue: Float) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [3] + encode7BitFirmata(timeBytes(rawValue.bitPattern))
    }
}

public struct FloatRegisterOperand: TaskRegisterOperand, FloatOperand {
    public var register: UInt8

    public init(register: UInt8) {
        self.register = register
    }

    public var operandBytes: [UInt8] {
        [2, register & 0x07]
    }
}

/// A boolean-valued operand — either ``BoolLiteralOperand`` or ``BoolRegisterOperand``.
/// Produced by the predicate ops (``FirmataTaskRecorder``'s `json.stringEquals`,
/// `bodyContains`, `digitalRead(pin:)`, …) and consumable directly by `ifTrue`.
public protocol BoolOperand: TaskOperand {
}

/// A boolean literal operand, backed by a `0`/`1` integer compared as an integer.
public struct BoolLiteralOperand: RawRepresentable, TaskLiteralOperand, BoolOperand {
    public var rawValue: Bool

    /// A compile-time boolean constant.
    public init(rawValue: Bool) {
        self.rawValue = rawValue
    }

    public var operandBytes: [UInt8] {
        [1] + encode7BitFirmata(timeBytes(UInt32(rawValue ? 1 : 0)))
    }
}

public struct BoolRegisterOperand: TaskRegisterOperand, BoolOperand {
    public var register: UInt8

    public init(register: UInt8) {
        self.register = register
    }

    public var operandBytes: [UInt8] {
        [0, register & 0x0F]
    }
}

public extension BoolRegisterOperand {
    /// Reinterpret an integer register as a boolean (`0`/non-zero) operand. Both kinds
    /// name the same `R[n]` in the device's 16 Int32 registers, so this is a pure rename.
    init(_ numberRegister: NumberRegisterOperand) {
        self.init(register: numberRegister.register)
    }
}

/// A handle to a **response body** recorded in a task — reach it via
/// ``TaskHTTPResponse/body`` and pass it to the `board.json` inspection ops
/// (`board.json.number(body, …)`, `.float`, `.stringEquals`, …).
///
/// A *borrowed* handle reads the device's live body, checked for staleness against the
/// generation captured when the request was recorded (a later request makes it stale —
/// test it with ``isValid()``). ``JSONOps/snapshot(_:into:)`` upgrades a handle **in place**
/// to an *owned* one that pins a persisted copy in a slot (so it survives later requests).
/// Unlike the value operands it carries a source reference rather than a comparable value,
/// so it is a standalone handle rather than a ``TaskOperand``.
/// Shared device-body handle — a JSON view (``JSONHandle``) or raw-string view
/// (``StringHandle``) of a recorded response body. The select/snapshot/free machinery
/// works on either.
protocol ResponseBodyHandle: AnyObject {
    var genReg: NumberRegisterOperand { get }
    var snapshotSlot: UInt8? { get set }
}

public final class JSONHandle: @unchecked Sendable, ResponseBodyHandle {
    /// Register holding the body generation captured at request time (borrowed handle).
    let genReg: NumberRegisterOperand
    /// Snapshot slot, once this handle has been snapshotted into an owned, persisted copy.
    var snapshotSlot: UInt8?
    /// The recorder that produced this handle (so ``isValid()`` can record into the task).
    weak var rec: FirmataTaskRecorder?

    init(genReg: NumberRegisterOperand, snapshotSlot: UInt8?, rec: FirmataTaskRecorder?) {
        self.genReg = genReg; self.snapshotSlot = snapshotSlot; self.rec = rec
    }

    /// Record a boolean that is `true` while the captured live body is still the current
    /// one, and branch on it with ``FirmataTaskRecorder/ifTrue(_:then:elseDo:)``. After a
    /// newer request replaces the live body this reads `false`; an **owned** snapshot is
    /// pinned, so it is always valid.
    @discardableResult
    public func isValid() -> BoolOperand {
        guard snapshotSlot == nil, let rec else { return .bool(true) }
        return rec.compare(genReg, .equal, rec.currentRequestCount())
    }
}

/// A captured string value — produced by ``JSONOps/getString(_:_:into:)``, which copies a
/// JSON string's content into a snapshot slot — inspected with the `board.string` ops.
/// Structurally a body handle like ``JSONHandle``; the two differ only in which ops they feed.
public final class StringHandle: @unchecked Sendable, ResponseBodyHandle {
    let genReg: NumberRegisterOperand
    var snapshotSlot: UInt8?
    weak var rec: FirmataTaskRecorder?

    init(genReg: NumberRegisterOperand, snapshotSlot: UInt8?, rec: FirmataTaskRecorder?) {
        self.genReg = genReg; self.snapshotSlot = snapshotSlot; self.rec = rec
    }

    /// `true` while the captured live body is still current (an owned snapshot is always valid).
    @discardableResult
    public func isValid() -> BoolOperand {
        guard snapshotSlot == nil, let rec else { return .bool(true) }
        return rec.compare(genReg, .equal, rec.currentRequestCount())
    }
}

/// A handle to an internet request recorded in a task — returned by
/// ``FirmataTaskRecorder/httpGet(_:statusInto:)`` / ``httpPost(_:body:statusInto:)``.
/// Branch on ``status``; inspect the payload as JSON via ``body`` (`board.json`), and
/// navigate to a string value with `board.json.getString(body, …)` for the `board.string` ops.
public struct TaskHTTPResponse: Sendable {
    /// Operand for the register holding the HTTP status code (`0` on failure).
    public let status: NumberRegisterOperand
    /// Handle to the response body for the `board.json` inspection ops. Navigate to a
    /// string value with `board.json.getString(body, "path")` to get a ``StringHandle``
    /// for the `board.string` ops.
    public let body: JSONHandle
}

/// Result-status codes the device records for an inspection op (matches the firmware's
/// `ST_*` values). Staleness of a borrowed body handle is surfaced on the host via
/// ``JSONHandle/isValid()``.
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
func httpOpBytes(method: UInt8, statusReg: NumberRegisterOperand, url: String, body: String?) -> [UInt8] {
    let u = Array(url.utf8)
    let b = Array((body ?? "").utf8)
    var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHttp,
                      method, statusReg.register & 0x0F]
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
