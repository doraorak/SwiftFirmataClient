import Testing
@testable import SwiftFirmataClient

// MARK: - Parser unit tests (no networking, no async)

@Suite("FirmataParser")
struct FirmataParserTests {

    // MARK: Standard messages

    @Test func analogMessage() {
        var p = FirmataParser()
        // channel 3, value = 0x155 (341 decimal) => LSB=0x55, MSB=0x02
        let msgs = feed(&p, [0xE3, 0x55, 0x02])
        guard case .analog(let ch, let val) = msgs.first else {
            Issue.record("Expected .analog, got \(msgs)")
            return
        }
        #expect(ch == 3)
        #expect(val == 0x55 | (0x02 << 7))  // 341
    }

    @Test func analogMessageMaxValue() {
        var p = FirmataParser()
        // 14-bit max: LSB=0x7F, MSB=0x7F => 0x3FFF (16383)
        let msgs = feed(&p, [0xE0, 0x7F, 0x7F])
        guard case .analog(_, let val) = msgs.first else {
            Issue.record("Expected .analog"); return
        }
        #expect(val == 0x3FFF)
    }

    @Test func digitalMessage() {
        var p = FirmataParser()
        // port 0: pins 0-6 = 0b1010101 (0x55), pin 7 = 1 => mask = 0x55 | 0x80 = 0xD5
        let msgs = feed(&p, [0x90, 0x55, 0x01])
        guard case .digital(let port, let mask) = msgs.first else {
            Issue.record("Expected .digital"); return
        }
        #expect(port == 0)
        #expect(mask == 0xD5)
    }

    @Test func digitalMessageAllPinsOff() {
        var p = FirmataParser()
        let msgs = feed(&p, [0x92, 0x00, 0x00])
        guard case .digital(let port, let mask) = msgs.first else {
            Issue.record("Expected .digital"); return
        }
        #expect(port == 2)
        #expect(mask == 0)
    }

    @Test func protocolVersion() {
        var p = FirmataParser()
        let msgs = feed(&p, [0xF9, 2, 8])
        guard case .protocolVersion(let v) = msgs.first else {
            Issue.record("Expected .protocolVersion"); return
        }
        #expect(v.major == 2)
        #expect(v.minor == 8)
    }

    @Test func systemResetIsIgnored() {
        var p = FirmataParser()
        // 0xFF produces no message; bytes after it still parse correctly
        let msgs = feed(&p, [0xFF, 0xF9, 2, 8])
        #expect(msgs.count == 1)
        guard case .protocolVersion = msgs.first else {
            Issue.record("Expected .protocolVersion after reset"); return
        }
    }

    // MARK: SysEx messages

    @Test func firmwareReport() {
        var p = FirmataParser()
        // "Hi" = H(72) i(105); encoded as LSB/MSB pairs: 72,0 105,0
        let msgs = feed(&p, [0xF0, 0x79, 1, 2, 72, 0, 105, 0, 0xF7])
        guard case .firmwareReport(let info) = msgs.first else {
            Issue.record("Expected .firmwareReport"); return
        }
        #expect(info.major == 1)
        #expect(info.minor == 2)
        #expect(info.name == "Hi")
    }

    @Test func firmwareReportEmptyName() {
        var p = FirmataParser()
        let msgs = feed(&p, [0xF0, 0x79, 3, 0, 0xF7])
        guard case .firmwareReport(let info) = msgs.first else {
            Issue.record("Expected .firmwareReport"); return
        }
        #expect(info.name == "")
    }

    @Test func capabilityResponse() {
        var p = FirmataParser()
        // Pin 0: digital-in(res=1), digital-out(res=1)  |  Pin 1: analog(res=10), pwm(res=8)
        let bytes: [UInt8] = [
            0xF0, 0x6C,
            0x00, 0x01, 0x01, 0x01, 0x7F,   // pin 0
            0x02, 0x0A, 0x03, 0x08, 0x7F,   // pin 1
            0xF7,
        ]
        let msgs = feed(&p, bytes)
        guard case .capabilityResponse(let pins) = msgs.first else {
            Issue.record("Expected .capabilityResponse"); return
        }
        #expect(pins.count == 2)
        #expect(pins[0].count == 2)
        #expect(pins[0][0].mode == .input && pins[0][0].resolution == 1)
        #expect(pins[0][1].mode == .output && pins[0][1].resolution == 1)
        #expect(pins[1][0].mode == .analog && pins[1][0].resolution == 10)
        #expect(pins[1][1].mode == .pwm && pins[1][1].resolution == 8)
    }

    @Test func analogMappingResponse() {
        var p = FirmataParser()
        // Pins 0-3: 0x7F (no analog), 0x7F, 0x00 (A0), 0x01 (A1)
        let bytes: [UInt8] = [0xF0, 0x6A, 0x7F, 0x7F, 0x00, 0x01, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .analogMappingResponse(let map) = msgs.first else {
            Issue.record("Expected .analogMappingResponse"); return
        }
        #expect(map == [0x7F, 0x7F, 0x00, 0x01])
    }

    @Test func pinStateResponse() {
        var p = FirmataParser()
        // pin=5, mode=OUTPUT, value=1 (7-bit: single byte 0x01)
        let bytes: [UInt8] = [0xF0, 0x6E, 5, 0x01, 0x01, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .pinStateResponse(let state) = msgs.first else {
            Issue.record("Expected .pinStateResponse"); return
        }
        #expect(state.pin == 5)
        #expect(state.mode == .output)
        #expect(state.value == 1)
    }

    @Test func pinStateResponsePWMHighValue() {
        var p = FirmataParser()
        // value = 255 = 0x7F | (0x01 << 7) => two 7-bit bytes: 0x7F, 0x01
        let bytes: [UInt8] = [0xF0, 0x6E, 9, 0x03, 0x7F, 0x01, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .pinStateResponse(let state) = msgs.first else {
            Issue.record("Expected .pinStateResponse"); return
        }
        #expect(state.mode == .pwm)
        #expect(state.value == 255)
    }

    @Test func stringData() {
        var p = FirmataParser()
        // "OK" => O(79): 79,0  K(75): 75,0
        let bytes: [UInt8] = [0xF0, 0x71, 79, 0, 75, 0, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .stringData(let s) = msgs.first else {
            Issue.record("Expected .stringData"); return
        }
        #expect(s == "OK")
    }

    @Test func i2cReply() {
        var p = FirmataParser()
        // address=0x48, register=0x00, data=[0xAB] encoded as 0x2B,0x01
        let bytes: [UInt8] = [
            0xF0, 0x77,
            0x48, 0x00,          // address 7-bit: 0x48 fits in low 7 bits
            0x00, 0x00,          // register 0
            0x2B, 0x01,          // data byte 0xAB = 0b10101011 => LSB=0x2B, MSB=0x01
            0xF7,
        ]
        let msgs = feed(&p, bytes)
        guard case .i2cReply(let reply) = msgs.first else {
            Issue.record("Expected .i2cReply"); return
        }
        #expect(reply.address == 0x48)
        #expect(reply.registerAddress == 0)
        #expect(reply.data == [0xAB])
    }

    @Test func extendedAnalog() {
        var p = FirmataParser()
        // pin=9, value=1000 = 0x3E8 => 7-bit chunks: 0x68 (bits 0-6), 0x07 (bits 7-9)
        let bytes: [UInt8] = [0xF0, 0x6F, 9, 0x68, 0x07, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .extendedAnalog(let pin, let val) = msgs.first else {
            Issue.record("Expected .extendedAnalog"); return
        }
        #expect(pin == 9)
        #expect(val == 1000)
    }

    @Test func unknownSysEx() {
        var p = FirmataParser()
        let bytes: [UInt8] = [0xF0, 0x50, 0x01, 0x02, 0xF7]
        let msgs = feed(&p, bytes)
        guard case .unknownSysEx(let id, let data) = msgs.first else {
            Issue.record("Expected .unknownSysEx"); return
        }
        #expect(id == 0x50)
        #expect(data == [0x01, 0x02])
    }

    // MARK: Multi-message and streaming

    @Test func multipleMessagesInSequence() {
        var p = FirmataParser()
        let bytes: [UInt8] = [
            0xF9, 2, 8,          // protocol version
            0xE0, 0x64, 0x00,    // analog ch0 = 100
            0x90, 0x0F, 0x00,    // digital port0 = 0x0F
        ]
        let msgs = feed(&p, bytes)
        #expect(msgs.count == 3)
        guard case .protocolVersion = msgs[0],
              case .analog = msgs[1],
              case .digital = msgs[2] else {
            Issue.record("Unexpected message sequence: \(msgs)"); return
        }
    }

    @Test func sysExSurroundedByStandardMessages() {
        var p = FirmataParser()
        let bytes: [UInt8] =
            [0xF9, 2, 8] +
            [0xF0, 0x79, 1, 0, 0xF7] +  // firmware: version 1.0, empty name
            [0xE2, 0x10, 0x00]           // analog ch2 = 16
        let msgs = feed(&p, bytes)
        #expect(msgs.count == 3)
    }

    @Test func byteByByteStreaming() {
        var p = FirmataParser()
        var results: [FirmataMessage] = []
        for byte in [UInt8(0xF9), 2, 8] {
            if let m = p.consume(byte) { results.append(m) }
        }
        #expect(results.count == 1)
        guard case .protocolVersion(let v) = results.first else {
            Issue.record("Expected .protocolVersion"); return
        }
        #expect(v.major == 2 && v.minor == 8)
    }

    // MARK: - Helper

    private func feed(_ parser: inout FirmataParser, _ bytes: [UInt8]) -> [FirmataMessage] {
        bytes.compactMap { parser.consume($0) }
    }
}
