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
