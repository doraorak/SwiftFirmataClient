/// Stateful byte-level parser for the Firmata protocol.
///
/// Feed bytes one at a time via ``consume(_:)``.
/// Returns a complete ``FirmataMessage`` when one is ready, or `nil` otherwise.
public struct FirmataParser: Sendable {

    private enum State: Sendable {
        case idle
        case waitingFirstData(UInt8)          // received command; need 1st data byte
        case waitingSecondData(UInt8, UInt8)  // received command + 1st data; need 2nd
        case sysex([UInt8])                   // collecting SysEx payload (after 0xF0)
    }

    private var state: State = .idle

    public init() {}

    /// Process one incoming byte. Returns a parsed message when a frame completes.
    public mutating func consume(_ byte: UInt8) -> FirmataMessage? {
        switch state {
        case .idle:
            return onIdle(byte)
        case .waitingFirstData(let cmd):
            return onFirstData(cmd: cmd, b1: byte)
        case .waitingSecondData(let cmd, let b1):
            state = .idle
            return onSecondData(cmd: cmd, b1: b1, b2: byte)
        case .sysex(var buf):
            if byte == Cmd.endSysEx {
                state = .idle
                return parseSysEx(buf)
            }
            buf.append(byte)
            state = .sysex(buf)
            return nil
        }
    }

    // MARK: - State transitions

    private mutating func onIdle(_ byte: UInt8) -> FirmataMessage? {
        switch byte {
        case Cmd.startSysEx:
            state = .sysex([])
        case Cmd.systemReset:
            break  // 1-byte message, no payload
        case Cmd.protocolVersion, Cmd.setPinMode, Cmd.setDigitalPinValue,
             0x90...0x9F, 0xE0...0xEF:
            state = .waitingFirstData(byte)  // 3-byte total: cmd + 2 data
        case 0xC0...0xCF, 0xD0...0xDF:
            state = .waitingFirstData(byte)  // 2-byte total: cmd + 1 data
        default:
            break
        }
        return nil
    }

    private mutating func onFirstData(cmd: UInt8, b1: UInt8) -> FirmataMessage? {
        switch cmd {
        case Cmd.protocolVersion, Cmd.setPinMode, Cmd.setDigitalPinValue,
             0x90...0x9F, 0xE0...0xEF:
            state = .waitingSecondData(cmd, b1)
        default:
            // 2-byte commands (0xC0-0xCF, 0xD0-0xDF): second byte was just consumed
            state = .idle
        }
        return nil
    }

    private func onSecondData(cmd: UInt8, b1: UInt8, b2: UInt8) -> FirmataMessage? {
        switch cmd {
        case Cmd.protocolVersion:
            return .protocolVersion(ProtocolVersion(major: b1, minor: b2))
        case 0x90...0x9F:
            let port = cmd & 0x0F
            let mask = (b1 & 0x7F) | ((b2 & 0x01) << 7)
            return .digital(port: port, pinMask: mask)
        case 0xE0...0xEF:
            let channel = cmd & 0x0F
            let value = UInt16(b1 & 0x7F) | (UInt16(b2 & 0x7F) << 7)
            return .analog(channel: channel, value: value)
        default:
            return nil
        }
    }

    // MARK: - SysEx parsing

    private func parseSysEx(_ buf: [UInt8]) -> FirmataMessage? {
        guard let id = buf.first else { return nil }
        let payload = Array(buf.dropFirst())

        switch id {
        case SysEx.reportFirmware:        return parseFirmware(payload)
        case SysEx.capabilityResponse:    return parseCapability(payload)
        case SysEx.analogMappingResponse: return .analogMappingResponse(channelByPin: payload)
        case SysEx.pinStateResponse:      return parsePinState(payload)
        case SysEx.stringData:            return .stringData(decode7BitPairs(payload))
        case SysEx.i2cReply:              return parseI2CReply(payload)
        case SysEx.extendedAnalog:        return parseExtendedAnalog(payload)
        case SysEx.schedulerData:         return parseScheduler(payload)
        default:                          return .unknownSysEx(id: id, data: payload)
        }
    }

    private func parseScheduler(_ data: [UInt8]) -> FirmataMessage? {
        guard let sub = data.first else { return nil }
        let body = Array(data.dropFirst())
        switch sub {
        case Sched.queryAllReply:
            return .schedulerTaskList(taskIds: body)

        case Sched.errorReply:
            guard let id = body.first else { return nil }
            return .schedulerError(taskId: id)

        case Sched.httpReply:
            // status (14-bit LE) followed by the body as 14-bit LSB/MSB pairs.
            guard body.count >= 2 else { return .httpResponse(status: 0, body: "") }
            let status = Int(body[0]) | (Int(body[1]) << 7)
            let text = decode7BitPairs(Array(body.dropFirst(2)))
            return .httpResponse(status: status, body: text)

        case Sched.queryReply:
            guard let id = body.first else { return nil }
            // payload (7-bit packed) = time_ms(4 LE) + len(2 LE) + pos(2 LE) + data[len]
            let encoded = Array(body.dropFirst())
            let decoded = decode7BitFirmata(num7BitOutBytes(encoded.count), encoded)
            guard decoded.count >= 8 else {
                return .schedulerTask(SchedulerTask(id: id, timeMs: 0, length: 0, position: 0, data: []))
            }
            var timeMs = UInt32(decoded[0])
            timeMs |= UInt32(decoded[1]) << 8
            timeMs |= UInt32(decoded[2]) << 16
            timeMs |= UInt32(decoded[3]) << 24
            let length = Int(decoded[4]) | (Int(decoded[5]) << 8)
            let pos    = Int(decoded[6]) | (Int(decoded[7]) << 8)
            let taskData = Array(decoded.dropFirst(8).prefix(length))
            return .schedulerTask(SchedulerTask(id: id, timeMs: timeMs, length: length,
                                                position: pos, data: taskData))

        default:
            return .unknownSysEx(id: SysEx.schedulerData, data: data)
        }
    }

    private func parseFirmware(_ data: [UInt8]) -> FirmataMessage? {
        guard data.count >= 2 else { return nil }
        let name = decode7BitPairs(Array(data.dropFirst(2)))
        return .firmwareReport(FirmwareInfo(major: data[0], minor: data[1], name: name))
    }

    private func parseCapability(_ data: [UInt8]) -> FirmataMessage {
        var pins: [[PinCapability]] = []
        var current: [PinCapability] = []
        var i = 0
        while i < data.count {
            if data[i] == 0x7F {
                pins.append(current)
                current = []
                i += 1
            } else if i + 1 < data.count {
                if let mode = PinMode(rawValue: data[i]) {
                    current.append(PinCapability(mode: mode, resolution: data[i + 1]))
                }
                i += 2
            } else {
                i += 1
            }
        }
        if !current.isEmpty { pins.append(current) }
        return .capabilityResponse(pins: pins)
    }

    private func parsePinState(_ data: [UInt8]) -> FirmataMessage? {
        guard data.count >= 3, let mode = PinMode(rawValue: data[1]) else { return nil }
        var value: Int32 = 0
        for (shift, b) in data[2...].enumerated() {
            value |= Int32(b & 0x7F) << (7 * shift)
        }
        return .pinStateResponse(PinState(pin: data[0], mode: mode, value: value))
    }

    private func parseI2CReply(_ data: [UInt8]) -> FirmataMessage? {
        guard data.count >= 4 else { return nil }
        let address  = UInt16(data[0]) | (UInt16(data[1] & 0x07) << 7)
        let register = UInt16(data[2]) | (UInt16(data[3]) << 7)
        var bytes: [UInt8] = []
        var i = 4
        while i + 1 < data.count {
            bytes.append(UInt8((UInt16(data[i]) | (UInt16(data[i + 1]) << 7)) & 0xFF))
            i += 2
        }
        return .i2cReply(I2CReply(address: address, register: register, data: bytes))
    }

    private func parseExtendedAnalog(_ data: [UInt8]) -> FirmataMessage? {
        guard let pin = data.first else { return nil }
        var value: Int32 = 0
        for (shift, b) in data[1...].enumerated() {
            value |= Int32(b & 0x7F) << (7 * shift)
        }
        return .extendedAnalog(pin: pin, value: value)
    }

    // MARK: - Helpers

    /// Decode consecutive LSB/MSB 7-bit pairs into a UTF-8 String.
    private func decode7BitPairs(_ data: [UInt8]) -> String {
        var scalars: [Unicode.Scalar] = []
        var i = 0
        while i + 1 < data.count {
            let codePoint = UInt32(data[i]) | (UInt32(data[i + 1]) << 7)
            if let scalar = Unicode.Scalar(codePoint) {
                scalars.append(scalar)
            }
            i += 2
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
