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
    static let reportAnalogPin:    UInt8 = 0xC0  // | channel
    static let reportDigitalPort:  UInt8 = 0xD0  // | port
    static let setPinMode:         UInt8 = 0xF4
    static let setDigitalPinValue: UInt8 = 0xF5
    static let protocolVersion:    UInt8 = 0xF9
    static let systemReset:        UInt8 = 0xFF
    static let startSysEx:         UInt8 = 0xF0
    static let endSysEx:           UInt8 = 0xF7
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

    // NON-STANDARD logic extension (this fork only; see NONSTANDARD.md).
    static let extSet:         UInt8 = 0x10  // R[d] = const
    static let extReadDigital: UInt8 = 0x11  // R[d] = digitalRead(pin)
    static let extReadAnalog:  UInt8 = 0x12  // R[d] = analogRead(channel)
    static let extIf:          UInt8 = 0x13  // if !(a op b) skip N bytes
    static let extSkip:        UInt8 = 0x14  // unconditional skip N bytes
}
