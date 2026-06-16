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
/// You receive one of these in the `build` closure of
/// ``FirmataClient/uploadTask(id:startDelayMs:repeatEveryMs:_:)``. The methods
/// mirror the live ``FirmataClient`` calls but **capture the bytes instead of
/// sending them** — so they're synchronous (no `await`). Insert ``delay(ms:)``
/// between actions to make the device wait while the task runs.
public struct FirmataTaskRecorder: Sendable {
    /// The recorded bytes so far (the task program). Usually you don't touch this
    /// directly — `uploadTask` reads it for you.
    public private(set) var bytes: [UInt8] = []

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
    ///   - value: `true` for HIGH, `false` for LOW.
    public mutating func digitalWrite(pin: UInt8, value: Bool) {
        bytes += [Cmd.setDigitalPinValue, pin, value ? 0x01 : 0x00]
    }

    /// Record writing all eight pins of a port at once (output pins only).
    /// - Parameters:
    ///   - port: The 8-pin group (`0` = pins 0-7, …).
    ///   - pinMask: One bit per pin (`1` = HIGH, `0` = LOW).
    public mutating func writeDigitalPort(_ port: UInt8, pinMask: UInt8) {
        bytes += [Cmd.digitalMessage | (port & 0x0F), pinMask & 0x7F, (pinMask >> 7) & 0x01]
    }

    /// Record a PWM write to a pin (0-15) in `.pwm` mode.
    /// - Parameters:
    ///   - pin: The PWM-capable pin number (0-15).
    ///   - value: Duty cycle within the pin's PWM resolution (e.g. `0`-`255`).
    public mutating func analogWrite(pin: UInt8, value: UInt16) {
        bytes += [Cmd.analogMessage | (pin & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
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
    // These emit sub-commands the *standard* Firmata Scheduler doesn't define, so
    // they only work with this project's firmware.

    /// Record `register = value` (one of 16 global Int32 registers, `0`–`15`).
    public mutating func setRegister(_ register: UInt8, to value: Int32) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extSet, register & 0x0F]
        bytes += encode7BitFirmata(timeBytes(UInt32(bitPattern: value)))
        bytes.append(Cmd.endSysEx)
    }

    /// Record `register = digitalRead(pin)` (stores `0`/`1`). The pin should be an
    /// input — record `setPinMode(pin, mode: .input)` earlier in the task.
    /// - Parameters:
    ///   - register: Destination register, `0`–`15`.
    ///   - pin: The board pin to read.
    public mutating func readDigital(into register: UInt8, pin: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extReadDigital,
                  register & 0x0F, pin & 0x7F, Cmd.endSysEx]
    }

    /// Record `register = analogRead(channel)` (the raw ADC value).
    /// - Parameters:
    ///   - register: Destination register, `0`–`15`.
    ///   - channel: Analog channel (A0 = `0`, …).
    public mutating func readAnalog(into register: UInt8, channel: UInt8) {
        bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extReadAnalog,
                  register & 0x0F, channel & 0x0F, Cmd.endSysEx]
    }

    /// Record an `if` (optionally with `else`). When the task runs, the device
    /// compares the two operands; the `then` block runs only if the comparison is
    /// true, otherwise the `elseDo` block (if given) runs.
    ///
    /// ```swift
    /// t.readAnalog(into: 0, channel: 0)
    /// t.ifTrue(.reg(0), .greaterThan, .const(512),
    ///     then:   { $0.digitalWrite(pin: 2, value: true) },
    ///     elseDo: { $0.digitalWrite(pin: 2, value: false) })
    /// ```
    ///
    /// - Parameters:
    ///   - a: Left operand — a register (`.reg(n)`) or a literal (`.const(v)`).
    ///   - op: The comparison (`.equal`, `.greaterThan`, …).
    ///   - b: Right operand — a register or a literal.
    ///   - then: Actions recorded into the "true" branch.
    ///   - elseDo: Optional actions recorded into the "false" branch.
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
        var m: [UInt8] = [Cmd.startSysEx, SysEx.schedulerData, Sched.extIf, op.rawValue]
        m += operandBytes(a)
        m += operandBytes(b)
        m += [UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
        return m
    }

    private static func skipMessage(byteCount: Int) -> [UInt8] {
        let n = UInt16(min(byteCount, 0x3FFF))
        return [Cmd.startSysEx, SysEx.schedulerData, Sched.extSkip,
                UInt8(n & 0x7F), UInt8((n >> 7) & 0x7F), Cmd.endSysEx]
    }
}

/// An operand for ``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)`` — either one of
/// the device's 16 registers or a literal value. (Non-standard extension.)
public enum SchedulerOperand: Sendable {
    case reg(UInt8)
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
