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

    public var description: String {
        switch self {
        case .input:       return "INPUT"
        case .output:      return "OUTPUT"
        case .analog:      return "ANALOG"
        case .pwm:         return "PWM"
        case .servo:       return "SERVO"
        case .shift:       return "SHIFT"
        case .i2c:         return "I2C"
        case .oneWire:     return "ONE_WIRE"
        case .stepper:     return "STEPPER"
        case .encoder:     return "ENCODER"
        case .serial:      return "SERIAL"
        case .inputPullup: return "INPUT_PULLUP"
        case .spi:         return "SPI"
        case .sonar:       return "SONAR"
        case .tone:        return "TONE"
        case .dht:         return "DHT"
        }
    }
}

// MARK: - I2C mode

public enum I2CMode: UInt8, Sendable {
    case write          = 0b00
    case readOnce       = 0b01
    case readContinuous = 0b10
    case stopReading    = 0b11
}

// MARK: - Internal protocol constants

enum Cmd {
    static let analogMessage:      UInt8 = 0xE0  // | channel (0-15)
    static let digitalMessage:     UInt8 = 0x90  // | port    (0-15)
    static let reportAnalogChannel:    UInt8 = 0xC0  // | channel
    static let reportDigitalPort:  UInt8 = 0xD0  // | port
    static let setPinMode:         UInt8 = 0xF4
    static let setDigitalPinValue: UInt8 = 0xF5
    static let protocolVersion:    UInt8 = 0xF9
    static let systemReset:        UInt8 = 0xFF
    static let startSysEx:         UInt8 = 0xF0
    static let endSysEx:           UInt8 = 0xF7
}

/// Encrypted Wi-Fi provisioning (non-standard; top-level SysEx in Firmata's
/// reserved user range). Hand the board Wi-Fi credentials — typically over BLE
/// before Wi-Fi is up — via an ephemeral X25519 ECDH handshake
/// (HKDF-SHA256 → AES-256-GCM). Binary fields are sent as 14-bit LSB/MSB pairs.
enum WiFiCfg {
    static let command: UInt8 = 0x0C
    static let set:     UInt8 = 0x00  // host→dev: <clientPub><nonce><ciphertext+tag>
    static let forget:  UInt8 = 0x01  // host→dev: clear stored creds
    static let query:   UInt8 = 0x02  // host→dev: request status
    static let begin:   UInt8 = 0x03  // host→dev: start handshake
    static let key:     UInt8 = 0x7E  // dev→host: <devicePub> (32 bytes)
    static let status:  UInt8 = 0x7F  // dev→host: <code> <ipLen> <ip>  (0 down, 1 connected, 2 rejected)
    static let hkdfSalt = "firmata-wifi-prov-v1"
}

enum SysEx {
    static let analogMappingQuery:    UInt8 = 0x69
    static let analogMappingResponse: UInt8 = 0x6A
    static let capabilityQuery:       UInt8 = 0x6B
    static let capabilityResponse:    UInt8 = 0x6C
    static let pinStateQuery:         UInt8 = 0x6D
    static let pinStateResponse:      UInt8 = 0x6E
    static let extendedAnalog:        UInt8 = 0x6F
    static let stringData:            UInt8 = 0x71
    static let i2cRequest:            UInt8 = 0x76
    static let i2cReply:              UInt8 = 0x77
    static let i2cConfig:             UInt8 = 0x78
    static let reportFirmware:        UInt8 = 0x79
    static let samplingInterval:      UInt8 = 0x7A
    static let samplingIntervalQuery: UInt8 = 0x7C
    static let schedulerData:         UInt8 = 0x7B
}

/// Scheduler sub-commands (first payload byte after `SysEx.schedulerData`).
enum Sched {
    static let create:        UInt8 = 0x00
    static let delete:        UInt8 = 0x01
    static let add:           UInt8 = 0x02
    static let delay:         UInt8 = 0x03
    static let schedule:      UInt8 = 0x04
    static let queryAll:      UInt8 = 0x05
    static let query:         UInt8 = 0x06
    static let reset:         UInt8 = 0x07
    static let errorReply:    UInt8 = 0x08
    static let queryAllReply: UInt8 = 0x09
    static let queryReply:    UInt8 = 0x0A
    static let httpReply:     UInt8 = 0x0B  // device -> host: HTTP status + body

    // Logic extension (see NONSTANDARD.md). Carried under the standard scheduler's
    // reserved extension command (0x7F), so a base scheduler ignores it cleanly.
    static let extCommand:     UInt8 = 0x7F  // EXTENDED_SCHEDULER_COMMAND
    static let extSet:         UInt8 = 0x10  // R[d] = const
    static let extDigitalRead: UInt8 = 0x11  // R[d] = digitalRead(pin)
    static let extAnalogRead:  UInt8 = 0x12  // R[d] = analogRead(channel)
    static let extIf:          UInt8 = 0x13  // if !(a op b) skip N bytes
    static let extSkip:        UInt8 = 0x14  // unconditional skip N bytes
    static let extHttp:        UInt8 = 0x15  // make an HTTP(S) request over Wi-Fi
    // Response-inspection ops (operate on the last HTTP response body):
    static let extJsonNum:     UInt8 = 0x16  // R[dst] = json number at path ×10^scale; R[found]
    static let extJsonStrEq:   UInt8 = 0x17  // R[dst] = (json string at path == s) ? 1 : 0
    static let extBodyContains: UInt8 = 0x18 // R[dst] = body contains s ? 1 : 0
    static let extJsonStrContains: UInt8 = 0x19 // R[dst] = (json string at path contains s) ? 1 : 0
    static let extArith:       UInt8 = 0x1A  // R[dst] = A <op> B  (op: 0+ 1- 2* 3/ 4%)
    static let extSetFloat:    UInt8 = 0x1B  // F[dst] = float const
    static let extArithFloat:      UInt8 = 0x1C  // F[dst] = A <op> B  (float; op 0+ 1- 2* 3/)
    static let extJsonFloat:   UInt8 = 0x1D  // F[dst] = json float at path; R[found]
    static let extJsonType:    UInt8 = 0x1E  // R[dst] = json type at path
    static let extJsonSize:    UInt8 = 0x1F  // R[dst] = byte length of value span at path
    static let extStringLen:   UInt8 = 0x20  // R[dst] = content length of json string at path (unused by client)
    static let extHeap:        UInt8 = 0x21  // R[freeReg]=free heap, R[largestReg]=largest block
    static let extRequestCount:     UInt8 = 0x22  // R[dst] = current request count (internal)
    static let extSnapshot:    UInt8 = 0x23  // copy value at path from live body into a slot
    static let extSelect:      UInt8 = 0x24  // pick inspection source (0=live, k=snapshot k-1)
    static let extFree:        UInt8 = 0x25  // free a snapshot slot
    static let extLastStatus:  UInt8 = 0x26  // R[dst] = status of last inspection op
    static let extCmp:         UInt8 = 0x27  // R[dst] = (A op B) ? 1 : 0
    // String ops over the selected string slot (board.string). `contains` reuses extBodyContains.
    static let extStringBodyLen: UInt8 = 0x28  // R[dst] = byte length of the selected string
    static let extStringEquals:  UInt8 = 0x29  // R[dst] = (selected string == s) ? 1 : 0
    static let extStringIndexOf: UInt8 = 0x2A  // R[dst] = index of s in the string, or -1
    static let extStringToNum:   UInt8 = 0x2B  // R[dst] = string parsed as int; R[found] = 0/1
    static let extJsonGetString: UInt8 = 0x2C  // copy a JSON string's content at path into a string slot
    static let extStringSetSlot: UInt8 = 0x2D  // set a string slot's content to a literal string (createString)
    static let extStringCopySlot: UInt8 = 0x2E  // copy one string slot's content into another (changeSlot/snapshotString)
}
