/* MARK: - Firmata Scheduler
   The Firmata Scheduler extension (SysEx 0x7B) lets the device store *tasks* —
   recorded sequences of Firmata messages with delays between them — and replay
   them autonomously, even after the host disconnects.
   Build a task with ``FirmataTaskRecorder`` (or the high-level
   ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``), upload it,
   then disconnect — the board keeps running it. */

/* The Firmata wire protocol carries time as raw integer milliseconds (scheduler
   delays, sampling interval) or microseconds (I2C config). The public API takes
   `Duration`; these convert to the wire unit, truncating sub-unit precision. */
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

/**
 Records the Firmata messages that make up a scheduler task.

 You never create one — ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``
 hands you a recorder in its closure (`{ board in … }`); every call captures bytes
 instead of sending them, so recording is synchronous (no `await`). The verbs
 mirror the live client, plus the on-device extension: registers, branches,
 arithmetic, HTTP + JSON/string inspection, and nested tasks. Insert ``delay(_:)``
 to make the device wait between actions while the task runs.
 */
public final class FirmataTaskRecorder {
    /// The recorded bytes so far (the task program). Usually you don't touch this
    /// directly — `uploadTask` reads it for you.
    public internal(set) var bytes: [UInt8] = []

    /// Append recorded op bytes — used by the `board.json` / `board.string` op builders.
    internal func emit(_ b: [UInt8]) { bytes += b }

    /// Next register handed out by ``digitalRead(pin:)`` / ``analogRead(channel:)``
    /// (descends the internal bank `R31 → R16`, then wraps).
    private var nextAutoRegister: TaskNumberRegister = .reg(31)
    /// Next float register auto-allocated for `getFloat` / float arithmetic
    /// (descends the internal bank `F15 → F8`, then wraps).
    private var nextAutoFloatRegister: TaskFloatRegister = .freg(15)
    /// Next JSON snapshot slot (0–1) and string slot (0–9), each wrapping.
    private var nextTaskJSONSlot: UInt8 = 0
    private var nextTaskStringSlot: UInt8 = 0
    /// Generation registers (for handle staleness) allocate bottom-up (R16↑) so they
    /// don't collide with the top-down (R31↓) pool used by reads/arithmetic results.
    private var nextRequestCountRegister: TaskNumberRegister = .reg(16)
    /// Next `once { }` guard index (0–31; the firmware keeps one 32-bit mask per task).
    private var nextOnceIndex: UInt8 = 0

    public init() {}

    /**
     Nested-branch recorder: inherits the parent's auto-allocation cursors so a
     branch never reuses a register/slot the parent already handed out (registers
     and slots are **global on the device**, shared across the whole task). The
     parent picks the advanced cursors back up with ``adoptCursors(from:)`` once the
     branch is recorded.
     */
    private init(inheriting parent: FirmataTaskRecorder) {
        nextAutoRegister         = parent.nextAutoRegister
        nextAutoFloatRegister    = parent.nextAutoFloatRegister
        nextTaskJSONSlot         = parent.nextTaskJSONSlot
        nextTaskStringSlot       = parent.nextTaskStringSlot
        nextRequestCountRegister = parent.nextRequestCountRegister
        nextOnceIndex            = parent.nextOnceIndex
    }

    /// Resume allocation where a nested-branch recorder left off, so registers/slots
    /// handed out inside a branch are never reused by later outer-scope allocations.
    private func adoptCursors(from child: FirmataTaskRecorder) {
        nextAutoRegister         = child.nextAutoRegister
        nextAutoFloatRegister    = child.nextAutoFloatRegister
        nextTaskJSONSlot         = child.nextTaskJSONSlot
        nextTaskStringSlot       = child.nextTaskStringSlot
        nextRequestCountRegister = child.nextRequestCountRegister
        nextOnceIndex            = child.nextOnceIndex
    }

    /**
     Record a pin-mode change (e.g. `.output` before writing it).
     - Parameters:
       - pin: The board pin — `.pin(13)`.
       - mode: The role the pin should take — see ``PinMode``.
     */
    public func setPinMode(_ pin: TaskPin, mode: PinMode) {
        bytes += [Cmd.setPinMode, pin.number, mode.rawValue]
    }

    /**
     Record driving a pin HIGH or LOW (the pin must be in `.output` mode).
     - Parameters:
       - pin: The board pin to drive — `.pin(2)`.
       - high: `true` for HIGH, `false` for LOW.
     */
    public func digitalWrite(pin: TaskPin, high: Bool) {
        bytes += [Cmd.setDigitalPinValue, pin.number, high ? 0x01 : 0x00]
    }

    /**
     Record writing all eight pins of a port at once (output pins only).
     - Parameters:
       - port: The 8-pin group (`0` = pins 0-7, …).
       - pinMask: One bit per pin (`1` = HIGH, `0` = LOW).
     */
    public func writeDigitalPort(_ port: UInt8, pinMask: UInt8) {
        bytes += [Cmd.digitalMessage | (port & 0x0F), pinMask & 0x7F, (pinMask >> 7) & 0x01]
    }

    /**
     Record a PWM write to a channel (0-15) in `.pwm` mode.
     - Parameters:
       - channel: The PWM channel — `.channel(3)` (the pin number for pins 0-15).
       - value: Duty cycle within the pin's PWM resolution (e.g. `0`-`255`).
     */
    public func analogWrite(channel: TaskChannel, value: UInt16) {
        bytes += [Cmd.analogMessage | (channel.number & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
    }

    /**
     Record an **extended** analog write — PWM on pins ≥ 16, or values wider than the
     14-bit standard analog message (e.g. servo microseconds). ``analogWrite(channel:value:)``
     only addresses channels 0–15; this addresses any pin. The scheduler replays it through
     the device's Firmata parser, so the board handles it exactly like a live one.
     - Parameters:
       - pin: The pin to drive — `.pin(25)`.
       - value: The value, sent as variable-length 7-bit chunks (non-negative).
     */
    public func extendedAnalogWrite(pin: TaskPin, value: Int32) {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.extendedAnalog, pin.number]
        var v = value
        repeat { m.append(UInt8(v & 0x7F)); v >>= 7 } while v != 0
        m.append(Cmd.endSysEx)
        bytes += m
    }

    /**
     Record a pause — the device waits this long before the next recorded action.
     A `delay` as the **final** message makes the whole task loop with that period
     (which is what ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)``'s
     `repeatEvery` adds for you).
     - Parameter duration: How long to wait (truncated to whole milliseconds — the
       resolution of the Firmata scheduler wire protocol).
     */
    public func delay(_ duration: Duration) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.delay]
        bytes += encode7BitFirmata(timeBytes(duration.firmataMilliseconds))
        bytes.append(Cmd.endSysEx)
    }

    /* Operand-valued writes (firmware 2.9+): the value comes from a register or a
       task variable instead of a compile-time literal — the bridge from "task
       computed something" to "pin outputs it". */

    /// Record a digital write whose level is an **operand**: HIGH when non-zero.
    /// The pin must be in `.output` mode.
    public func digitalWrite(pin: TaskPin, high: TaskBool) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extWritePin,
                  0, pin.number & 0x7F] + high.operandBytes + [Cmd.endSysEx]
    }

    /// Record an analog write whose value is an **operand** (register / variable /
    /// literal), routed by the pin's mode on the device: PWM duty for `.pwm` pins,
    /// degrees-or-µs for `.servo` pins. Works for any pin 0–127. Float operands truncate.
    public func analogWrite(pin: TaskPin, value: TaskOperand) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extWritePin,
                  1, pin.number & 0x7F] + value.operandBytes + [Cmd.endSysEx]
    }

    /// Record a servo write whose angle/pulse comes from an **operand** — the same
    /// wire op as ``analogWrite(pin:value:)`` (the device routes by pin mode).
    public func servoWrite(pin: TaskPin, value: TaskOperand) {
        analogWrite(pin: pin, value: value)
    }

    /// Record a servo write: `0…180` = degrees, `≥ 544` = pulse µs (same dual
    /// meaning as the live call). Put the pin in `.servo` mode first.
    public func servoWrite(pin: TaskPin, value: Int32) {
        if pin.number <= 15 {
            let v = UInt16(clamping: value)
            bytes += [Cmd.analogMessage | (pin.number & 0x0F), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
        } else {
            extendedAnalogWrite(pin: pin, value: value)
        }
    }

    /// Record a PWM frequency/resolution config (`PWM_CONFIG` — same bytes as the live
    /// call; the replay parser shares the handler). Firmware 2.16+.
    public func configurePWM(pin: TaskPin, frequencyHz: UInt32, resolutionBits: UInt8 = 8) {
        let f = min(frequencyHz, 0x1F_FFFF)
        bytes += [Cmd.startSysEx, SysEx.pwmConfig, pin.number & 0x7F,
                  UInt8(f & 0x7F), UInt8((f >> 7) & 0x7F), UInt8((f >> 14) & 0x7F),
                  min(max(resolutionBits, 1), 14),
                  Cmd.endSysEx]
    }

    /// Record a **tone**: beep a passive buzzer on a `.pwm` pin at `hz` for `duration`.
    /// Pure composition — `configurePWM(hz)` + 50 % duty + delay + duty 0 — so the
    /// timing runs on-device like everything else. Firmware 2.16+.
    public func tone(pin: TaskPin, hz: UInt32, duration: Duration) {
        configurePWM(pin: pin, frequencyHz: hz, resolutionBits: 8)
        extendedAnalogWrite(pin: pin, value: 128)          // 50 % of 8-bit
        delay(duration)
        extendedAnalogWrite(pin: pin, value: 0)
    }

    /// Record a PWM frequency set from an **operand** — the pitch comes out of a
    /// register/variable at run time (e.g. tone follows a sensor). Puts the pin in
    /// PWM mode at 8-bit duty resolution. Firmware 2.16+.
    public func configurePWM(pin: TaskPin, frequency: TaskNumber) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extPwmFreq,
                  pin.number & 0x7F] + frequency.operandBytes + [Cmd.endSysEx]
    }

    /// Record a delay whose **milliseconds come from an operand** (register/variable/
    /// literal, evaluated at run time). Negative values delay 0. Firmware 2.16+.
    public func delay(_ milliseconds: TaskNumber) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extDelayOp]
               + milliseconds.operandBytes + [Cmd.endSysEx]
    }

    /// Record a **tone with operand pitch and/or duration** — either side may be a
    /// literal (`.number(440)`) or a register/variable. Firmware 2.16+.
    public func tone(pin: TaskPin, hz: TaskNumber, duration: TaskNumber) {
        configurePWM(pin: pin, frequency: hz)
        extendedAnalogWrite(pin: pin, value: 128)
        delay(duration)
        extendedAnalogWrite(pin: pin, value: 0)
    }

    /**
     Record a **run-once block**: `body` executes on the task's FIRST pass only —
     later passes (a `repeatEvery:` task looping, or re-entry inside a `repeat`)
     skip it. The guard is a per-task once-mask bit in the firmware, cleared when
     the task is (re)scheduled, so re-uploading the task arms it again. Up to 32
     `once` blocks per task. Firmware 2.16+.

     ```swift
     try await client.uploadTask(id: 1, repeatEvery: .seconds(5)) { board in
         board.once { $0.displayConfigure(kind: .sh1106) }   // init once
         board.displayPrint(.freg(0), line: 2)               // every pass
     }
     ```
     */
    public func once(_ body: (FirmataTaskRecorder) -> Void) {
        precondition(nextOnceIndex < 32, "a task supports at most 32 once { } blocks")
        let idx = nextOnceIndex
        nextOnceIndex += 1
        let bodyRec = FirmataTaskRecorder(inheriting: self); body(bodyRec)
        adoptCursors(from: bodyRec)
        let bodyBytes = bodyRec.bytes
        let skip = UInt16(min(bodyBytes.count, 0x3FFF))
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extOnce,
                  idx, UInt8(skip & 0x7F), UInt8((skip >> 7) & 0x7F), Cmd.endSysEx]
        bytes += bodyBytes
    }

    /// Record "deliver `payload` to module `id`" — the task-side twin of
    /// ``FirmataClient/sendToModule(id:payload:)`` (firmware 2.9+). Payload bytes
    /// are the module's own protocol; typed wrappers (like ``ir``) build them for you.
    public func moduleOp(id: UInt8, payload: [UInt8]) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extModuleOp,
                  id & 0x7F] + payload.map { $0 & 0x7F } + [Cmd.endSysEx]
    }

    // MARK: Nested tasks (a task that spawns tasks)

    /**
     Record "upload and schedule task `id`" as an action of *this* task — the child is
     replaced (delete → create → fill → schedule) every time this action runs, with
     no host involved. `board.deleteTask(id:)` is the counterpart.

     ```swift
     board.addTask(id: 2, repeatEvery: .milliseconds(250)) { alarm in
         alarm.digitalWrite(pin: .pin(2), high: true)
     }
     ```

     Registers and slots are global across tasks: the child inherits this recorder's
     auto-allocation cursors (like a branch), and pinned registers (`into: .reg(n)`)
     are the way to pass values parent → child. The child must fit the 512-byte task
     budget and its ~8/7-encoded upload also counts toward the parent's 512. Never
     reuse the enclosing task's own id — the firmware refuses the slot.

     - Parameters:
       - id: Child task id `0–127`; an existing task with this id is replaced.
       - startDelay: Delay before the child's first run, from the moment this action runs.
       - repeatEvery: Loop period (recorded as a trailing delay); `nil` = run once.
       - build: Records the child's actions into the nested recorder.
     */
    public func addTask(
        id: UInt8,
        startDelay: Duration = .zero,
        repeatEvery: Duration? = nil,
        _ build: (FirmataTaskRecorder) -> Void
    ) {
        let child = FirmataTaskRecorder(inheriting: self)
        build(child)
        if let period = repeatEvery { child.delay(period) }
        adoptCursors(from: child)
        let data = child.bytes

        // The same replace → create → fill → schedule sequence uploadTask sends,
        // recorded into this task instead of sent over the transport.
        deleteTask(id: id)
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.create, id & 0x7F,
                  UInt8(data.count & 0x7F), UInt8((data.count >> 7) & 0x7F), Cmd.endSysEx]
        var offset = 0
        while offset < data.count {
            let end = min(offset + 48, data.count)                 // uploadTask's chunk size
            bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.add, id & 0x7F]
            bytes += encode7BitFirmata(Array(data[offset..<end]))
            bytes.append(Cmd.endSysEx)
            offset = end
        }
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.schedule, id & 0x7F]
        bytes += encode7BitFirmata(timeBytes(startDelay.firmataMilliseconds))
        bytes.append(Cmd.endSysEx)
    }

    /**
     Record "**delete task `id`**" — stop and remove a task from within this task
     (typically one spawned earlier with ``addTask(id:startDelay:repeatEvery:_:)``).
     A silent no-op on the device if no such task exists. Deleting the task's
     *own* id ends it after the current run (it won't reschedule).
     */
    public func deleteTask(id: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.delete, id & 0x7F, Cmd.endSysEx]
    }

    /* MARK: I2C (standard Firmata — drive an I2C device from a task)
       The scheduler replays these through the device's Firmata parser, so a task
       can talk to an I2C peripheral (e.g. write command/data bytes to an SSD1306
       OLED) with no host connected. Call `configureI2C` once (it begins the bus),
       then `i2cWrite` as needed. (Reads aren't offered here — their reply has no
       host to receive it inside an autonomous task.) */

    /**
     Record an I2C bus config/begin (`delay` between a register-write and the
     following read; truncated to whole microseconds). Do this once at the start of
     a task that uses I2C.
     */
    public func configureI2C(delay: Duration = .zero) {
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

    /**
     Record an **I²C register read into a register** (non-standard extension) — the device
     writes `registerAddress`, reads `count` (1–4) bytes, and stores them **big-endian** in
     `R[dst]`, so a task can act on an I²C sensor with no host connected. The reply is
     consumed on-device (not sent to a host) — unlike the live ``FirmataClient/i2cReadOnce``.
     - Parameters:
       - address: 7-bit I²C device address.
       - registerAddress: the peripheral register to read (a sub-address inside the device,
         **not** an on-device logic register).
       - count: how many bytes to read (1–4), packed MSB-first into the result.
       - into: destination register; auto-allocated (R15↓) if omitted.
     */
    @discardableResult
    public func i2cRead(address: UInt16, registerAddress: UInt16, count: UInt8 = 1,
                        into: TaskNumberRegister? = nil) -> TaskNumber {
        let dst = into ?? allocateRegister()
        let c = min(max(count, 1), 4)
        emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extI2CRead,
              UInt8(address & 0x7F),
              UInt8(registerAddress & 0x7F), UInt8((registerAddress >> 7) & 0x7F),
              c, dst.index & Sched.intRegisterMask, Cmd.endSysEx])
        return dst
    }

    /**
     Record sending a **device string to a connected host** (non-standard extension) — while
     the task runs, the board emits a standard `STRING_DATA` to its master (TCP or BLE),
     arriving as ``FirmataMessage/stringData(_:)``. A no-op if no host is connected.
     (Note: a string passed to the device via ``FirmataClient/sendString(_:)`` is only logged
     to the board's serial console; this is the reverse, board → host, direction.)
     */
    public func sendString(_ s: String) {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extEmitString]
        appendLengthPrefixed(&m, s)
        m.append(Cmd.endSysEx)
        emit(m)
    }

    /* MARK: NON-STANDARD logic extension (see NONSTANDARD.md)
       On-device registers + `if`/`else` so a task can make decisions by itself.
       These ride under the scheduler's reserved EXTENDED_SCHEDULER_COMMAND (0x7F),
       so a standard scheduler ignores them gracefully; only this project's firmware
       acts on them. The Scheduler control protocol itself is unchanged.
       The device has 16 global Int32 "registers" (`R0`–`R15`), shared across all
       tasks and reset by a system reset. You put values into them (a constant, or a
       pin/analog reading) and then branch on them with ``ifTrue(_:_:_:then:elseDo:)``. */

    /**
     Record `R[dst] = value` — load a constant into one of the device's 16
     global Int32 registers.
     - Parameters:
       - dst: Destination register — `.reg(3)`.
       - value: The signed 32-bit constant to store — `.number(512)`.
     */
    public func setRegister(_ dst: TaskNumberRegister, to value: TaskNumberLiteral) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSet, dst.index & Sched.intRegisterMask]
        bytes += encode7BitFirmata(timeBytes(UInt32(bitPattern: value.rawValue)))
        bytes.append(Cmd.endSysEx)
    }

    /**
     Record `R[dst] = R[src]` — copy one register into another. Compiles as
     `src + 0 → dst` (the arithmetic op takes register operands), so it needs no
     dedicated firmware op and works on any firmware with arithmetic (2.12+).
     */
    public func setRegister(_ dst: TaskNumberRegister, to source: TaskNumberRegister) {
        _ = add(source, .number(0), into: dst)
    }

    /**
     Record `F[dst] = F[src]` — copy one float register into another
     (`src + 0.0 → dst` via the float arithmetic op).
     */
    public func setFloatRegister(_ dst: TaskFloatRegister, to source: TaskFloatRegister) {
        _ = addFloat(source, .float(0), into: dst)
    }

    /**
     Record `register = digitalRead(pin)` (stores `0`/`1`). The pin should be an
     input — record `setPinMode(.pin(p), mode: .input)` earlier in the task.
     - Parameters:
       - register: Destination register — `.boolReg(1)`.
       - pin: The board pin to read — `.pin(7)`.
     */
    public func digitalRead(into register: TaskBoolRegister, pin: TaskPin) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extDigitalRead,
                  register.index & Sched.intRegisterMask, pin.number & 0x7F, Cmd.endSysEx]
    }

    /**
     Record `register = analogRead(channel)` — read an analog input into a register.

     - Important: `channel` is an **analog channel index, not a pin number**.
       Channels are numbered `A0 = 0`, `A1 = 1`, … and map to specific GPIOs on the
       board (the mapping comes from ``FirmataClient/queryAnalogMapping()``). So
       `channel: 0` reads whatever pin is wired to A0 — not GPIO 0.
     - Parameters:
       - register: Destination register — `.reg(2)`.
       - channel: Analog channel — `.channel(0)` (`A0 = 0`, …).
     */
    public func analogRead(into register: TaskNumberRegister, channel: TaskChannel) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extAnalogRead,
                  register.index & Sched.intRegisterMask, channel.number & 0x0F, Cmd.endSysEx]
    }

    /**
     Record `digitalRead(pin)` into an **auto-allocated** register and return that
     register as a ``TaskOperand`` — so you can drop the read straight into a
     comparison. (A recorder can't return a live value; the read happens on the
     device when the task runs, and this hands you the register it lands in.)

     ```swift
     let pressed = board.digitalRead(pin: .pin(7))         // -> TaskBool
     board.ifTrue(pressed, .equal, .number(0),             // active-low button
         then: { $0.digitalWrite(pin: .pin(2), high: true) })
     ```

     Auto-allocated registers cycle `R15 → R0`; if you need a **named** register
     (e.g. to reuse it as an explicit `into:` destination), use ``digitalRead(into:pin:)``.
     Read into a local first if you'll reuse it, since a later auto-read may reuse the
     same register.
     - Parameter pin: The board pin to read — `.pin(7)` (put it in `.input`/`.inputPullup` first).
     - Returns: A ``TaskBool`` holding `0`/`1` — drop it straight into `ifTrue`/`compare`.
     */
    public func digitalRead(pin: TaskPin) -> TaskBool {
        let r = TaskBoolRegister(allocateRegister())
        digitalRead(into: r, pin: pin)
        return r
    }

    /**
     Record `analogRead(channel)` into an **auto-allocated** register and return
     it as a ``TaskNumber`` for use in ``ifTrue(_:_:_:then:elseDo:)``. See
     ``digitalRead(pin:)`` for the allocation rules; use ``analogRead(into:channel:)``
     when you need a named register.
     - Parameter channel: Analog channel — `.channel(0)` (`A0 = 0`, …), **not** a pin number.
     - Returns: A ``TaskNumber`` holding the reading.
     */
    public func analogRead(channel: TaskChannel) -> TaskNumber {
        let r = allocateRegister(); analogRead(into: r, channel: channel); return r
    }

    /// Hand out the next auto-allocated register, descending the internal bank
    /// `R31 → R16` then wrapping (never touches the public `R0–R15`).
    internal func allocateRegister() -> TaskNumberRegister {
        let r = nextAutoRegister
        let raw = r.index
        nextAutoRegister = .reg((raw == 16) ? 31 : (raw - 1))
        return r
    }

    internal func allocateFloatRegister() -> TaskFloatRegister {
        let r = nextAutoFloatRegister
        let raw = r.index
        nextAutoFloatRegister = .freg((raw == 8) ? 15 : (raw - 1))
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
        nextRequestCountRegister = .reg((raw == 31) ? 16 : (raw + 1))
        return r
    }

    /**
     Record an `if`/`else` the device evaluates while the task runs: `then` records the
     actions for `a op b` true, `elseDo` (optional) the false side. Each branch closure
     receives its own nested recorder (`$0`); branches nest freely, including delays.

     ```swift
     board.ifTrue(.reg(0), .greaterThan, .number(512),
         then:   { $0.digitalWrite(pin: .pin(2), high: true) },
         elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })
     ```

     - Parameters:
       - a: Left operand — register or literal.
       - op: `.equal` `.notEqual` `.lessThan` `.greaterThan` `.lessOrEqual` `.greaterOrEqual`
         (float operands promote the comparison to float).
       - b: Right operand.
       - then: Actions for the true case.
       - elseDo: Actions for the false case; omit for a plain `if`.
     */
    public func ifTrue(
        _ a: TaskOperand,
        _ op: TaskComparison,
        _ b: TaskOperand,
        then: (FirmataTaskRecorder) -> Void,
        elseDo: ((FirmataTaskRecorder) -> Void)? = nil
    ) {
        /* Branch recorders inherit our allocation cursors and hand them back, so a
           register/slot used in a branch is never reused by the outer scope (or the
           other branch) — they all name the same global device registers/slots. */
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

    /**
     Record a **counted repeat** — run `body` exactly `times` times, pausing `gap` between
     iterations (not after the last). Runs on-device via a native scheduler loop op, so
     the task stays a fixed handful of bytes regardless of the count. Any recorded actions
     are allowed inside, including nested repeats (up to the firmware's nesting depth).
     `times == 0` runs `body` zero times.

     ```swift
     board.repeat(times: 4, gap: .milliseconds(220)) {
         $0.irSendRC6(0x11)          // volume down, four distinct presses
     }
     ```
     */
    public func `repeat`(times count: Int, gap: Duration = .zero,
                         _ body: (FirmataTaskRecorder) -> Void) {
        let bodyRec = FirmataTaskRecorder(inheriting: self); body(bodyRec)
        adoptCursors(from: bodyRec)
        let bodyBytes = bodyRec.bytes
        let endBytes = Self.loopEndMessage()
        bytes += Self.loopMessage(count: count, gapMs: Int(gap.firmataMilliseconds),
                                  skipBytes: bodyBytes.count + endBytes.count)
        bytes += bodyBytes
        bytes += endBytes
    }

    /**
     Record an `if` driven by a **boolean operand** — the `then` block runs when
     `condition` is true (non-zero), otherwise `elseDo` (if given). Pass a value from
     any predicate op: ``digitalRead(pin:)``, `string.equals`, `bodyContains`,
     ``compare(_:_:_:into:)``, etc.

     ```swift
     let pressed = board.digitalRead(pin: .pin(7))        // -> TaskBool
     board.ifTrue(pressed) { $0.digitalWrite(pin: .pin(2), high: true) }
     ```

     This is shorthand for ``ifTrue(_:_:_:then:elseDo:)`` with `.notEqual, .number(0)`.
     - Parameters:
       - condition: A boolean operand (a `0`/non-zero register or literal).
       - then: Actions to run when `condition` is true.
       - elseDo: Optional actions to run when `condition` is false.
     */
    public func ifTrue(
        _ condition: TaskBool,
        then: (FirmataTaskRecorder) -> Void,
        elseDo: ((FirmataTaskRecorder) -> Void)? = nil
    ) {
        ifTrue(condition, .notEqual, .number(0), then: then, elseDo: elseDo)
    }

    /**
     Record an `if` that branches on a JSON value **kind** from
     ``TaskJSONOps/getType(_:_:into:)`` — compared typed against a ``TaskJSONValueType``
     (e.g. `is: .string`), rather than a raw number. Shorthand for `== type.rawValue`.

     ```swift
     let kind = board.json.getType(resp.body, "result")
     board.ifTrue(kind, is: .string) { $0.digitalWrite(pin: .pin(2), high: true) }
     ```
     */
    public func ifTrue(
        _ kind: TaskJSONType,
        is type: TaskJSONValueType,
        then: (FirmataTaskRecorder) -> Void,
        elseDo: ((FirmataTaskRecorder) -> Void)? = nil
    ) {
        ifTrue(kind, .equal, .number(type.rawValue), then: then, elseDo: elseDo)
    }

    /**
     Record `R[dst] = (a op b) ? 1 : 0` and return it as a **reusable boolean** — store
     it once and branch on it (possibly several times) with ``ifTrue(_:then:elseDo:)``,
     instead of repeating the comparison inline. Operands may be registers or literals;
     if either side is a float the device promotes to float. Result register
     auto-allocated (R15↓) unless `into:` is given. (Non-standard extension.)

     ```swift
     let isUp = board.compare(pct, .greaterThan, .number(0))   // -> TaskBool
     board.ifTrue(isUp) { $0.digitalWrite(pin: .pin(2), high: true) }
     ```
     */
    @discardableResult
    public func compare(_ a: TaskOperand, _ op: TaskComparison, _ b: TaskOperand,
                        into: TaskBoolRegister? = nil) -> TaskBool {
        let dst = into ?? TaskBoolRegister(allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extCmp,
                          op.rawValue, dst.index & Sched.intRegisterMask]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /**
     Record an HTTP(S) `GET` the device performs over its own Wi-Fi while the task
     runs (certs validated on-device). The status lands in a register (`0` on
     failure) and the body is retained for the ``json``/``string`` inspection ops:

     ```swift
     let resp = board.httpGet("https://api.example.com/state")
     let level = board.json.getNumber(resp.body, "sensor.level")
     board.ifTrue(resp.status, .equal, .number(200)) { $0.digitalWrite(pin: .pin(2), high: true) }
     ```

     - Important: URL is ASCII and URL + body must fit one SysEx frame (≲ 500 B);
       the request blocks the device (~8 s worst case) — keep request tasks infrequent.
     - Parameters:
       - url: The `http://`/`https://` URL.
       - statusInto: Status register; auto-allocated when omitted.
     - Returns: A ``TaskHTTPResponse`` — branch on `.status`, inspect `.body`.
     */
    @discardableResult
    public func httpGet(_ url: String, statusInto: TaskNumberRegister? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 0, statusReg: statusReg, url: url, body: nil)
        return makeResponse(statusReg: statusReg)
    }

    /**
     Record an **internet `POST`** (Wi-Fi, `Content-Type: application/json`).
     Returns a ``TaskHTTPResponse`` (status auto-allocated unless `statusInto:` is given);
     inspect the body with the JSON/string ops.
     */
    @discardableResult
    public func httpPost(_ url: String, body: String, statusInto: TaskNumberRegister? = nil) -> TaskHTTPResponse {
        let statusReg = statusInto ?? allocateRegister()
        bytes += httpOpBytes(method: 1, statusReg: statusReg, url: url, body: body)
        return makeResponse(statusReg: statusReg)
    }

    // Capture the body generation into a register so the body handle can be staleness-checked.
    private func makeResponse(statusReg: TaskNumberRegister) -> TaskHTTPResponse {
        let gReg = allocateGenRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, gReg.index & Sched.intRegisterMask, Cmd.endSysEx]
        return TaskHTTPResponse(status: statusReg,
                                body: TaskResponseBody(genReg: gReg, snapshotSlot: nil, rec: self))
    }

    // MARK: Handle lifecycle — typed select / snapshot / free

    /// Select the JSON body source for the next inspection op: an owned snapshot slot, or
    /// the live body checked for staleness against the handle's captured generation.
    internal func selectJSON(_ body: TaskResponseBody) {
        if let slot = body.snapshotSlot {
            emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                  slot.firmwareIndex + 1, 0x00, Cmd.endSysEx])
        } else {
            emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
                  0x00, body.genReg.index & Sched.intRegisterMask, Cmd.endSysEx])
        }
    }

    /// Select a string's slot for the next `board.string` op.
    internal func selectString(_ s: TaskString) {
        emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSelect,
              s.slot.firmwareIndex + 1, 0x00, Cmd.endSysEx])
    }

    /// Read the device's current request count (body generation) into a register.
    /// Used by ``TaskResponseBody/isValid()`` to compare against a handle's captured generation.
    internal func currentRequestCount(into: TaskNumberRegister? = nil) -> TaskNumber {
        let dst = into ?? allocateRegister()
        emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extRequestCount, dst.index & Sched.intRegisterMask, Cmd.endSysEx])
        return dst
    }

    internal func appendLengthPrefixed(_ m: inout [UInt8], _ s: String) {
        let b = Array(s.utf8)
        m += [UInt8(b.count & 0x7F), UInt8((b.count >> 7) & 0x7F)]
        m += b.map { $0 & 0x7F }      // ASCII expected
    }

    // MARK: Arithmetic (on integer registers)

    /**
     Record `R[dst] = a + b`. Operands are registers and/or literals; the result
     register is auto-allocated (R15↓) unless `into:` is given. Returns it as an
     operand for chaining / `ifTrue`. (64-bit intermediates on the device avoid
     overflow; `÷` and `%` by zero yield 0.)
     */
    @discardableResult
    public func add(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumber {
        arith(0, a, b, into)
    }
    /// Record `R[dst] = a - b`. See ``add(_:_:into:)``.
    @discardableResult
    public func subtract(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumber {
        arith(1, a, b, into)
    }
    /// Record `R[dst] = a * b`. See ``add(_:_:into:)``.
    @discardableResult
    public func multiply(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumber {
        arith(2, a, b, into)
    }
    /// Record `R[dst] = a / b` (integer division; `÷0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func divide(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumber {
        arith(3, a, b, into)
    }
    /// Record `R[dst] = a % b` (`%0` → 0). See ``add(_:_:into:)``.
    @discardableResult
    public func modulo(_ a: TaskOperand, _ b: TaskOperand, into: TaskNumberRegister? = nil) -> TaskNumber {
        arith(4, a, b, into)
    }

    private func arith(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                _ into: TaskNumberRegister?) -> TaskNumberRegister {
        let dst = into ?? allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArith, sub, dst.index & Sched.intRegisterMask]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    // MARK: Float registers (8 of them, F0–F7)

    /**
     Record `F[dst] = value` — load a `Float` constant into a float register.
     (Mirrors ``setRegister(_:to:)`` for the integer registers.)
     - Parameters:
       - dst: Destination float register — `.freg(0)`.
       - value: The `Float` constant to store — `.float(100.0)`.
     */
    public func setFloatRegister(_ dst: TaskFloatRegister, to value: TaskFloatLiteral) {
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSetFloat, dst.index & Sched.floatRegisterMask]
        m += encode7BitFirmata(timeBytes(value.rawValue.bitPattern))
        m.append(Cmd.endSysEx); bytes += m
    }

    /**
     Record `F[dst] = a + b` (float). Operands may be float/int registers or
     literals (ints promote to float). Result float register auto-allocated
     (F7↓) unless `into:` is given. `÷0` → 0.
     */
    @discardableResult
    public func addFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloat {
        arithF(0, a, b, into)
    }
    /// Record `F[dst] = a - b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func subtractFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloat {
        arithF(1, a, b, into)
    }
    /// Record `F[dst] = a * b` (float). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func multiplyFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloat {
        arithF(2, a, b, into)
    }
    /// Record `F[dst] = a / b` (float; `÷0` → 0). See ``addFloat(_:_:into:)``.
    @discardableResult
    public func divideFloat(_ a: TaskOperand, _ b: TaskOperand, into: TaskFloatRegister? = nil) -> TaskFloat {
        arithF(3, a, b, into)
    }

    private func arithF(_ sub: UInt8, _ a: TaskOperand, _ b: TaskOperand,
                                 _ into: TaskFloatRegister?) -> TaskFloatRegister {
        let dst = into ?? allocateFloatRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extArithFloat, sub, dst.index & Sched.floatRegisterMask]
        m += a.operandBytes
        m += b.operandBytes
        m.append(Cmd.endSysEx); bytes += m
        return dst
    }

    /// Record reading heap stats into registers — `free` heap and `largest`
    /// contiguous block — so a task can gate an allocation on available memory.
    @discardableResult
    public func heapStats(freeInto: TaskNumberRegister? = nil,
                                   largestInto: TaskNumberRegister? = nil) -> (free: TaskNumber, largest: TaskNumber) {
        let f = freeInto ?? allocateRegister()
        let l = largestInto ?? allocateRegister()
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHeap,
                  f.index & Sched.intRegisterMask, l.index & Sched.intRegisterMask, Cmd.endSysEx]
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

    /// LOOP_BEGIN: `count`, `gap` (ms between iterations), and `skip` (bytes to jump past the
    /// body + LOOP_END when `count == 0`). All three are 14-bit little-endian 7-bit pairs.
    private static func loopMessage(count: Int, gapMs: Int, skipBytes: Int) -> [UInt8] {
        let c = UInt16(min(max(0, count), 0x3FFF))
        let g = UInt16(min(max(0, gapMs), 0x3FFF))
        let s = UInt16(min(skipBytes, 0x3FFF))
        return [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extLoop,
                UInt8(c & 0x7F), UInt8((c >> 7) & 0x7F),
                UInt8(g & 0x7F), UInt8((g >> 7) & 0x7F),
                UInt8(s & 0x7F), UInt8((s >> 7) & 0x7F), Cmd.endSysEx]
    }

    private static func loopEndMessage() -> [UInt8] {
        [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extLoopEnd, Cmd.endSysEx]
    }

    /**
     JSON inspection of recorded response bodies — call as
     `board.json.getNumber(resp.body, "path")`. (A tiny value-type view over the recorder;
     no instance to manage.)
     */
    public var json: TaskJSONOps { TaskJSONOps(rec: self) }

    /// Raw-string inspection of a recorded response body — `board.string` ops over a
    /// ``TaskString`` from ``TaskJSONOps/getString(_:_:into:)``.
    public var string: TaskStringOps { TaskStringOps(rec: self) }
}

/**
 JSON inspection of a recorded response body (reached via ``FirmataTaskRecorder/json``).
 Each call takes a ``TaskResponseBody`` (from ``TaskHTTPResponse/body`` or ``TaskJSONOps/snapshot(_:into:)``):
 it selects that source on the device — a snapshot, or the live body checked for staleness
 against the handle's generation — then records the op. Branch on results with `board.ifTrue`.
 */
public struct TaskJSONOps {
    internal let rec: FirmataTaskRecorder

    /// `R` = number at `path` × 10^`scaledBy` (truncated; also parses quoted numbers).
    @discardableResult
    public func getNumber(_ body: TaskResponseBody, _ path: String, scaledBy: UInt8 = 0,
                          into: TaskNumberRegister? = nil, found: TaskNumberRegister? = nil) -> TaskNumber {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        let fnd = found ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonNum,
                          dst.index & Sched.intRegisterMask, fnd.index & Sched.intRegisterMask, scaledBy]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `F` = floating-point number at `path` (handles quoted / fractional / exponent).
    @discardableResult
    public func getFloat(_ body: TaskResponseBody, _ path: String,
                         into: TaskFloatRegister? = nil, found: TaskNumberRegister? = nil) -> TaskFloat {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateFloatRegister()
        let fnd = found ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonFloat,
                          dst.index & Sched.floatRegisterMask, fnd.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = (the whole body contains `text`) ? 1 : 0.
    @discardableResult
    public func bodyContains(_ body: TaskResponseBody, _ text: String, into: TaskBoolRegister? = nil) -> TaskBool {
        rec.selectJSON(body)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extBodyContains, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, text)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /**
     Record the JSON value **kind** at `path` into a register, returned as a typed
     ``TaskJSONType``. Branch on it typed with
     ``FirmataTaskRecorder/ifTrue(_:is:then:elseDo:)`` (e.g. `is: .string`); it's also
     usable as any ``TaskNumber`` (it holds the ``TaskJSONValueType`` raw value).
     */
    @discardableResult
    public func getType(_ body: TaskResponseBody, _ path: String, into: TaskNumberRegister? = nil) -> TaskJSONType {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonType, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return TaskJSONType(index: dst.index)
    }
    /// `R` = byte length of the value span at `path` (size before snapshotting).
    @discardableResult
    public func getSize(_ body: TaskResponseBody, _ path: String, into: TaskNumberRegister? = nil) -> TaskNumber {
        rec.selectJSON(body)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonSize, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /**
     Navigate to the **string** value at `path`, capture its content (unquoted) into a
     ``TaskStringSlot``, and return a ``TaskString`` for the `board.string` ops. Slot
     auto-allocated (0–9) unless given; release it with `board.string.free(_:)`.
     (Reads the **live** body, so call it right after the `httpGet`.)
     */
    @discardableResult
    public func getString(_ body: TaskResponseBody, _ path: String, into slot: TaskStringSlot? = nil) -> TaskString {
        let dst = slot ?? rec.allocateTaskStringSlot()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extJsonGetString, dst.firmwareIndex]
        rec.appendLengthPrefixed(&m, path)
        m.append(Cmd.endSysEx); rec.emit(m)
        return TaskString(slot: dst, rec: rec)
    }

    /**
     Persist the **whole current body** into a JSON snapshot slot so it survives the next
     request, **upgrading `body` in place** (its ``TaskResponseBody/snapshotSlot`` is set). Slot
     auto-allocated (0–1) unless given. Call right after the `httpGet` you want to keep.
     */
    public func snapshot(_ body: TaskResponseBody, into slot: TaskJSONSlot? = nil) {
        let s = slot ?? rec.allocateTaskJSONSlot()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extSnapshot,
                  s.firmwareIndex, 0x00, 0x00, Cmd.endSysEx])      // pathLen 0 = whole body
        body.snapshotSlot = s
    }

    /// Free the JSON snapshot slot held by `body` (if any).
    public func free(_ body: TaskResponseBody) {
        guard let slot = body.snapshotSlot else { return }
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extFree, slot.firmwareIndex, Cmd.endSysEx])
        body.snapshotSlot = nil
    }
}

/**
 Raw-string inspection of a captured string (reached via ``FirmataTaskRecorder/string``).
 Each call takes a ``TaskString`` — from ``TaskJSONOps/getString(_:_:into:)`` or
 ``createString(_:)`` — selects its slot on the device, then records the op.
 */
public struct TaskStringOps {
    internal let rec: FirmataTaskRecorder

    /**
     Make a standalone string from a literal, stored in a ``TaskStringSlot`` —
     auto-allocated (0–9, wrapping) unless you pass an explicit `into:` slot.
     Pin a slot when the string must be visible to another task, or to opt out of
     auto-allocation wraparound (mirrors ``TaskJSONOps/getString(_:_:into:)``).
     Release it with `board.string.free(_:)`.
     */
    @discardableResult
    public func createString(_ value: String, into slot: TaskStringSlot? = nil) -> TaskString {
        let dst = slot ?? rec.allocateTaskStringSlot()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringSetSlot, dst.firmwareIndex]
        rec.appendLengthPrefixed(&m, value)
        m.append(Cmd.endSysEx); rec.emit(m)
        return TaskString(slot: dst, rec: rec)
    }

    /// Reserve a string slot and return a handle WITHOUT writing anything to it — unlike
    /// ``createString(_:into:)`` this emits no wire bytes, so re-running it every pass of a
    /// repeating task won't clear the slot. Use it as the destination for a producer that
    /// fills the slot on the device (e.g. `board.irReceiveRawText`): the string reads empty
    /// until the first write, then persists. The slot's memory is (re)allocated on first write.
    public func reserveString(into slot: TaskStringSlot? = nil) -> TaskString {
        TaskString(slot: slot ?? rec.allocateTaskStringSlot(), rec: rec)
    }
    /// `R` = byte length of the string.
    @discardableResult
    public func length(_ s: TaskString, into: TaskNumberRegister? = nil) -> TaskNumber {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringBodyLen, dst.index & Sched.intRegisterMask, Cmd.endSysEx])
        return dst
    }
    /// `R` = (string == `value`) ? 1 : 0.
    @discardableResult
    public func equals(_ s: TaskString, _ value: String, into: TaskBoolRegister? = nil) -> TaskBool {
        rec.selectString(s)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringEquals, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, value)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = (string contains `substring`) ? 1 : 0.
    @discardableResult
    public func contains(_ s: TaskString, _ substring: String, into: TaskBoolRegister? = nil) -> TaskBool {
        rec.selectString(s)
        let dst = into ?? TaskBoolRegister(rec.allocateRegister())
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extBodyContains, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, substring)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = index of `substring` in the string, or `-1` if absent.
    @discardableResult
    public func indexOf(_ s: TaskString, _ substring: String, into: TaskNumberRegister? = nil) -> TaskNumber {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringIndexOf, dst.index & Sched.intRegisterMask]
        rec.appendLengthPrefixed(&m, substring)
        m.append(Cmd.endSysEx); rec.emit(m)
        return dst
    }
    /// `R` = the string parsed as an integer (leading sign + digits); `R[found]` = 0/1.
    @discardableResult
    public func toInt(_ s: TaskString, into: TaskNumberRegister? = nil, found: TaskNumberRegister? = nil) -> TaskNumber {
        rec.selectString(s)
        let dst = into ?? rec.allocateRegister()
        let fnd = found ?? rec.allocateRegister()
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extStringToNum,
                  dst.index & Sched.intRegisterMask, fnd.index & Sched.intRegisterMask, Cmd.endSysEx])
        return dst
    }
    /// Free the device slot held by a string handle.
    public func free(_ s: TaskString) {
        rec.emit([Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extFree, s.slot.firmwareIndex, Cmd.endSysEx])
    }
}

/**
 A typed value the device evaluates in ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``
 and arithmetic — an integer/float register or a literal. (Non-standard extension.)
 When either side of a comparison/op is a float, the device promotes to float.

 This is the root protocol; the recorder's ops hand back the concrete kind that
 matches what they produce — ``TaskNumber``, ``TaskFloat``, or ``TaskBool`` —
 so the static type tells you what a value *is*. Build literals with
 ``number(_:)`` / ``float(_:)`` / ``bool(_:)``, and name registers explicitly with
 ``reg(_:)`` / ``freg(_:)``.
 */
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
        precondition(index < Sched.intRegisterCount, "register index must be 0…31 (R0-15 public, R16-31 auto/internal)")
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [0, index & Sched.intRegisterMask]
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
        precondition(index < Sched.floatRegisterCount, "float register index must be 0…15 (F0-7 public, F8-15 auto/internal)")
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [2, index & Sched.floatRegisterMask]
    }
}

/**
 A boolean-valued operand — either ``TaskBoolLiteral`` or ``TaskBoolRegister``.
 Produced by the predicate ops (``FirmataTaskRecorder``'s `string.equals`,
 `bodyContains`, `digitalRead(pin:)`, …) and consumable directly by `ifTrue`.
 */
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
        precondition(index < Sched.intRegisterCount, "register index must be 0…31 (R0-15 public, R16-31 auto/internal)")
        self.index = index
    }

    public var operandBytes: [UInt8] {
        [0, index & Sched.intRegisterMask]
    }
}

public extension TaskBoolRegister {
    /// Reinterpret an integer register as a boolean (`0`/non-zero) operand. Both kinds
    /// name the same `R[n]` in the device's 16 Int32 registers, so this is a pure rename.
    init(_ numberRegister: TaskNumberRegister) {
        self.init(index: numberRegister.index)
    }
}

/// A board **pin**, by number — write it as `.pin(13)`. A typed wrapper so the task API
/// never takes a bare integer where a pin is meant (distinct from a ``TaskChannel``).
public struct TaskPin: Sendable {
    public let number: UInt8
    public init(_ number: UInt8) {
        precondition(number <= 127, "pin must be 0…127 (Firmata uses a 7-bit pin number)")
        self.number = number
    }
    /// A pin by number — `.pin(13)`.
    public static func pin(_ number: UInt8) -> TaskPin { TaskPin(number) }
}

/// An **analog channel** index (`A0 = 0`, …) — write it as `.channel(0)`. A typed wrapper,
/// distinct from a ``TaskPin`` (a channel maps to a pin via ``FirmataClient/queryAnalogMapping()``).
public struct TaskChannel: Sendable {
    public let number: UInt8
    public init(_ number: UInt8) {
        precondition(number <= 15, "analog channel must be 0…15 (the recorder's analog ops use a 4-bit channel)")
        self.number = number
    }
    /// An analog channel by number — `.channel(0)`.
    public static func channel(_ number: UInt8) -> TaskChannel { TaskChannel(number) }
}

/// One of the device's **JSON snapshot slots** (`0`–`1`) — a typed slot, like a register operand.
public struct TaskJSONSlot: Sendable {
    public let index: UInt8
    public init(_ index: UInt8) {
        precondition(index <= 1, "JSON slot must be 0 or 1 (2 snapshot slots)")
        self.index = index
    }
    internal var firmwareIndex: UInt8 { index & 0x01 }            // device snapshot pool: 0–1
}

/// One of the device's **string slots** (`0`–`9`) — a typed slot, like a register operand.
public struct TaskStringSlot: Sendable {
    public let index: UInt8
    public init(_ index: UInt8) {
        precondition(index <= 9, "string slot must be 0…9 (10 string slots)")
        self.index = index
    }
    internal var firmwareIndex: UInt8 { (index % 10) + 2 }        // device snapshot pool: 2–11 (after the 2 JSON slots)
}

/**
 A handle to a **JSON response body** — reach it via ``TaskHTTPResponse/body`` and pass it
 to the `board.json` inspection ops. A *borrowed* handle reads the device's live body,
 checked for staleness against the generation captured at request time (a later request
 makes it stale — test it with ``isValid()``). ``TaskJSONOps/snapshot(_:into:)``
 upgrades it **in place** to an owned copy in a ``TaskJSONSlot`` that survives later requests.
 */
public final class TaskResponseBody: @unchecked Sendable {
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

/**
 A handle to an internet request recorded in a task — returned by
 ``FirmataTaskRecorder/httpGet(_:statusInto:)`` / ``httpPost(_:body:statusInto:)``.
 Branch on ``status``; inspect the payload as JSON via ``body`` (`board.json`), and
 navigate to a string value with `board.json.getString(body, …)` for the `board.string` ops.
 */
public struct TaskHTTPResponse: Sendable {
    /// Operand for the register holding the HTTP status code (`0` on failure).
    public let status: TaskNumberRegister
    /**
     Handle to the response body for the `board.json` inspection ops. Navigate to a
     string value with `board.json.getString(body, "path")` to get a ``TaskString``
     for the `board.string` ops.
     */
    public let body: TaskResponseBody
}

/**
 The JSON value **kind** at a path — the typed result of ``TaskJSONOps/getType(_:_:into:)``.
 It holds a ``TaskJSONValueType`` in one of the device's registers; branch on it typed with
 ``FirmataTaskRecorder/ifTrue(_:is:then:elseDo:)``, and it's also usable as any ``TaskNumber``.
 */
public struct TaskJSONType: TaskRegister, TaskNumber {
    public var index: UInt8
    public init(index: UInt8) {
        precondition(index < Sched.intRegisterCount, "register index must be 0…31 (R0-15 public, R16-31 auto/internal)")
        self.index = index
    }
    public var operandBytes: [UInt8] { [0, index & Sched.intRegisterMask] }
}

/// JSON value kinds — the cases of a ``TaskJSONType`` from ``TaskJSONOps/getType(_:_:into:)``.
/// Use with ``FirmataTaskRecorder/ifTrue(_:is:then:elseDo:)`` (e.g. `is: .string`).
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

/**
 Encode a `SCHED_EXT_HTTP` op (used both inside tasks and for live requests).
 Layout: `F0 7B 7F 15 method statusReg urlLo urlHi url[…] bodyLo bodyHi body[…] F7`.
 URL/body are sent as raw 7-bit ASCII; lengths are 14-bit little-endian. The
 response body is retained on the device for the inspection ops.
 */
internal func httpOpBytes(method: UInt8, statusReg: TaskNumberRegister, url: String, body: String?) -> [UInt8] {
    let u = Array(url.utf8)
    let b = Array((body ?? "").utf8)
    var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extHttp,
                      method, statusReg.index & Sched.intRegisterMask]
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
