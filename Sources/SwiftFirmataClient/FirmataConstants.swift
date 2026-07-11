// MARK: - Pin modes

/// Pin operation modes, as defined in Firmata protocol §2.
public enum PinMode: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case input       = 0x00
    case output      = 0x01
    case analog      = 0x02
    case pwm         = 0x03
    case servo       = 0x04
    case shift       = 0x05
    case i2c         = 0x06
    case oneWire     = 0x07
    case stepper     = 0x08
    case encoder     = 0x09
    case serial      = 0x0A
    case inputPullup = 0x0B
    case spi         = 0x0C
    case sonar       = 0x0D
    case tone        = 0x0E
    case dht         = 0x0F

    // ESP32 firmware extensions (block 0x10+, clear of the standard table above).
    case inputPulldown = 0x10   // internal pull-down (no pulls on GPIO 34–39)
    case touch         = 0x11   // capacitive touch — reads via analog channels 6–15 (T0–T9)
    case dac           = 0x12   // true 8-bit analog out (GPIO 25/26)

    public var description: String {
        switch self {
        case .input:         return "INPUT"
        case .output:        return "OUTPUT"
        case .analog:        return "ANALOG"
        case .pwm:           return "PWM"
        case .servo:         return "SERVO"
        case .shift:         return "SHIFT"
        case .i2c:           return "I2C"
        case .oneWire:       return "ONE_WIRE"
        case .stepper:       return "STEPPER"
        case .encoder:       return "ENCODER"
        case .serial:        return "SERIAL"
        case .inputPullup:   return "INPUT_PULLUP"
        case .spi:           return "SPI"
        case .sonar:         return "SONAR"
        case .tone:          return "TONE"
        case .dht:           return "DHT"
        case .inputPulldown: return "INPUT_PULLDOWN"
        case .touch:         return "TOUCH"
        case .dac:           return "DAC"
        }
    }
}

// MARK: - Touch channels

public extension FirmataChannel {
    /**
     The analog channel for ESP32 touch sensor `Tn` (0–9). Touch readings ride the
     analog paths on **channels 6–15** (ADC owns 0–5): set the sensor's GPIO to
     `.touch`, then report/read its touch channel like any analog channel.
     T0–T9 → GPIO 4, 0, 2, 15, 13, 12, 14, 27, 33, 32.
     */
    static func touch(_ sensor: UInt8) -> FirmataChannel { .channel(6 + min(sensor, 9)) }
}

public extension TaskChannel {
    /// Task-side spelling of ``FirmataChannel/touch(_:)`` — touch sensor `Tn` (0–9) as
    /// its analog channel (6–15) for `board.analogRead`.
    static func touch(_ sensor: UInt8) -> TaskChannel { .channel(6 + min(sensor, 9)) }
}

// MARK: - I2C mode

public enum I2CMode: UInt8, Sendable {
    case write          = 0b00
    case readOnce       = 0b01
    case readContinuous = 0b10
    case stopReading    = 0b11
}

// MARK: - Internal protocol constants

internal enum Cmd {
    internal static let analogMessage:      UInt8 = 0xE0  // | channel (0-15)
    internal static let digitalMessage:     UInt8 = 0x90  // | port    (0-15)
    internal static let reportAnalogChannel:    UInt8 = 0xC0  // | channel
    internal static let reportDigitalPort:  UInt8 = 0xD0  // | port
    internal static let setPinMode:         UInt8 = 0xF4
    internal static let setDigitalPinValue: UInt8 = 0xF5
    internal static let protocolVersion:    UInt8 = 0xF9
    internal static let systemReset:        UInt8 = 0xFF
    internal static let startSysEx:         UInt8 = 0xF0
    internal static let endSysEx:           UInt8 = 0xF7
}

/**
 Encrypted Wi-Fi provisioning (non-standard; top-level SysEx in Firmata's
 reserved user range). Hand the board Wi-Fi credentials — typically over BLE
 before Wi-Fi is up — via an ephemeral X25519 ECDH handshake
 (HKDF-SHA256 → AES-256-GCM). Binary fields are sent as 14-bit LSB/MSB pairs.
 */
internal enum WiFiCfg {
    internal static let command: UInt8 = 0x0C
    internal static let set:     UInt8 = 0x00  // host→dev: <clientPub><nonce><ciphertext+tag>
    internal static let forget:  UInt8 = 0x01  // host→dev: clear stored creds
    internal static let query:   UInt8 = 0x02  // host→dev: request status
    internal static let begin:   UInt8 = 0x03  // host→dev: start handshake
    internal static let key:     UInt8 = 0x7E  // dev→host: <devicePub> (32 bytes)
    internal static let status:  UInt8 = 0x7F  // dev→host: <code> <ipLen> <ip>  (0 down, 1 connected, 2 rejected)
    internal static let hkdfSalt = "firmata-wifi-prov-v1"
}

internal enum SysEx {
    internal static let analogMappingQuery:    UInt8 = 0x69
    internal static let analogMappingResponse: UInt8 = 0x6A
    internal static let capabilityQuery:       UInt8 = 0x6B
    internal static let capabilityResponse:    UInt8 = 0x6C
    internal static let pinStateQuery:         UInt8 = 0x6D
    internal static let pinStateResponse:      UInt8 = 0x6E
    internal static let extendedAnalog:        UInt8 = 0x6F
    internal static let stringData:            UInt8 = 0x71
    internal static let i2cRequest:            UInt8 = 0x76
    internal static let i2cReply:              UInt8 = 0x77
    internal static let i2cConfig:             UInt8 = 0x78
    internal static let reportFirmware:        UInt8 = 0x79
    internal static let samplingInterval:      UInt8 = 0x7A
    internal static let samplingIntervalQuery: UInt8 = 0x7C
    internal static let moduleData:            UInt8 = 0x0D  // module subsystem (user range)
    internal static let pwmConfig:             UInt8 = 0x0E  // per-pin LEDC freq/resolution (user range)
    internal static let servoConfig:           UInt8 = 0x70
    internal static let schedulerData:         UInt8 = 0x7B
}

/// Scheduler sub-commands (first payload byte after `SysEx.schedulerData`).
/// Module-subsystem subcommands (first byte after `SysEx.moduleData`).
internal enum Module {
    internal static let query:     UInt8 = 0x00  // host -> dev: list installed modules
    internal static let listReply: UInt8 = 0x7F  // dev -> host: <n> [<id> <maj> <min> <len> <name…>]*
    // Any other first byte 0x01–0x7E is a module id: the rest of the payload is the
    // module's own protocol (host -> module, or module event -> host).
}

internal enum Sched {
    internal static let create:        UInt8 = 0x00
    internal static let delete:        UInt8 = 0x01
    internal static let add:           UInt8 = 0x02
    internal static let delay:         UInt8 = 0x03
    internal static let schedule:      UInt8 = 0x04
    internal static let queryAll:      UInt8 = 0x05
    internal static let query:         UInt8 = 0x06
    internal static let reset:         UInt8 = 0x07
    internal static let errorReply:    UInt8 = 0x08
    internal static let queryAllReply: UInt8 = 0x09
    internal static let queryReply:    UInt8 = 0x0A
    internal static let httpReply:     UInt8 = 0x0B  // device -> host: HTTP status + body
    internal static let regReply:      UInt8 = 0x0C  // device -> host: R0-15 + F0-7 snapshot

    // Logic extension (see NONSTANDARD.md). Carried under the standard scheduler's
    // reserved extension command (0x7F), so a base scheduler ignores it cleanly.
    internal static let extCommand:     UInt8 = 0x7F  // EXTENDED_SCHEDULER_COMMAND
    internal static let extSet:         UInt8 = 0x10  // R[d] = const
    internal static let extDigitalRead: UInt8 = 0x11  // R[d] = digitalRead(pin)
    internal static let extAnalogRead:  UInt8 = 0x12  // R[d] = analogRead(channel)
    internal static let extIf:          UInt8 = 0x13  // if !(a op b) skip N bytes
    internal static let extSkip:        UInt8 = 0x14  // unconditional skip N bytes
    internal static let extHttp:        UInt8 = 0x15  // make an HTTP(S) request over Wi-Fi
    // Response-inspection ops (operate on the last HTTP response body):
    internal static let extJsonNum:     UInt8 = 0x16  // R[dst] = json number at path ×10^scale; R[found]
    internal static let extBodyContains: UInt8 = 0x18 // R[dst] = body contains s ? 1 : 0
    // 0x17 / 0x19 are firmware ops (json-string-at-path == / contains) the client doesn't
    // emit — reachable via getString + string.equals/contains. Reserved; don't reuse.
    internal static let extArith:       UInt8 = 0x1A  // R[dst] = A <op> B  (op: 0+ 1- 2* 3/ 4%)
    internal static let extSetFloat:    UInt8 = 0x1B  // F[dst] = float const
    internal static let extArithFloat:      UInt8 = 0x1C  // F[dst] = A <op> B  (float; op 0+ 1- 2* 3/)
    internal static let extJsonFloat:   UInt8 = 0x1D  // F[dst] = json float at path; R[found]
    internal static let extJsonType:    UInt8 = 0x1E  // R[dst] = json type at path
    internal static let extJsonSize:    UInt8 = 0x1F  // R[dst] = byte length of value span at path
    // 0x20 is a firmware-only string-length op the client doesn't emit. Reserved; don't reuse.
    internal static let extHeap:        UInt8 = 0x21  // R[freeReg]=free heap, R[largestReg]=largest block
    internal static let extRequestCount:     UInt8 = 0x22  // R[dst] = current request count (internal)
    internal static let extSnapshot:    UInt8 = 0x23  // copy value at path from live body into a slot
    internal static let extSelect:      UInt8 = 0x24  // pick inspection source (0=live, k=snapshot k-1)
    internal static let extFree:        UInt8 = 0x25  // free a snapshot slot
    internal static let extLastStatus:  UInt8 = 0x26  // R[dst] = status of last inspection op
    internal static let extCmp:         UInt8 = 0x27  // R[dst] = (A op B) ? 1 : 0
    // String ops over the selected string slot (board.string). `contains` reuses extBodyContains.
    internal static let extStringBodyLen: UInt8 = 0x28  // R[dst] = byte length of the selected string
    internal static let extStringEquals:  UInt8 = 0x29  // R[dst] = (selected string == s) ? 1 : 0
    internal static let extStringIndexOf: UInt8 = 0x2A  // R[dst] = index of s in the string, or -1
    internal static let extStringToNum:   UInt8 = 0x2B  // R[dst] = string parsed as int; R[found] = 0/1
    internal static let extJsonGetString: UInt8 = 0x2C  // copy a JSON string's content at path into a string slot
    internal static let extStringSetSlot: UInt8 = 0x2D  // set a string slot's content to a literal string (createString)
    internal static let extStringCopySlot: UInt8 = 0x2E  // copy one string slot's content into another (changeSlot)
    internal static let extI2CRead:     UInt8 = 0x2F  // R[dst] = bytes read from an I2C device, big-endian (i2cRead)
    internal static let extEmitString:  UInt8 = 0x30  // device -> host STRING_DATA from a running task (sendString)
    internal static let extRegQuery:    UInt8 = 0x31  // report all registers to the host (regReply)
    internal static let extWritePin:    UInt8 = 0x32  // write a pin from an operand: kind pin <operand>
    internal static let extModuleOp:    UInt8 = 0x33  // deliver a payload to a module from a task
    internal static let extLoop:        UInt8 = 0x34  // begin a counted loop: count gap skip (skip past body when count==0)
    internal static let extLoopEnd:     UInt8 = 0x35  // end of a counted loop: decrement, jump back + gap, or exit
    internal static let extPwmFreq:     UInt8 = 0x36  // set a PWM pin's frequency from an operand (runtime value)
    internal static let extDelayOp:     UInt8 = 0x37  // delay milliseconds from an operand (runtime value)
    internal static let extOnce:        UInt8 = 0x38  // once-per-task-lifetime guard: idx, skip body when already run

    // Task-extension register file. R0-15 / F0-7 are public (user); R16-31 / F8-15 are internal
    // (auto-allocation + library scratch). The wire index masks derive from the counts.
    internal static let intRegisterCount:   UInt8 = 32
    internal static let floatRegisterCount: UInt8 = 16
    internal static let intRegisterMask:    UInt8 = intRegisterCount - 1     // 0x1F
    internal static let floatRegisterMask:  UInt8 = floatRegisterCount - 1   // 0x0F
}
