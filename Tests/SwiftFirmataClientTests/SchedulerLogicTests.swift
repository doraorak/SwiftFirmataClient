import Testing
@testable import SwiftFirmataClient

@Suite("SchedulerLogic")
struct SchedulerLogicTests {

    @Test func setRegisterEncoding() {
        var r = FirmataTaskRecorder()
        r.setRegister(3, to: 512)
        // F0 7B 10 reg=3 <512 as Encoder7Bit of [0,2,0,0] = 0,4,0,0,0> F7
        #expect(r.bytes == [0xF0, 0x7B, 0x10, 0x03, 0x00, 0x04, 0x00, 0x00, 0x00, 0xF7])
    }

    @Test func readDigitalAndAnalogEncoding() {
        var r = FirmataTaskRecorder()
        r.readDigital(into: 1, pin: 7)
        r.readAnalog(into: 2, channel: 0)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x11, 0x01, 0x07, 0xF7,   // R1 = digitalRead(7)
            0xF0, 0x7B, 0x12, 0x02, 0x00, 0xF7,   // R2 = analogRead(A0)
        ])
    }

    @Test func ifElseLaysOutSkipsCorrectly() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(0), .greaterThan, .const(512),
            then:   { $0.digitalWrite(pin: 2, value: true) },
            elseDo: { $0.digitalWrite(pin: 2, value: false) })

        // IF (op=3 greaterThan) reg0 vs const512, skip=9 (then-block + trailing SKIP)
        // then: digitalWrite(2,HIGH) [3]  +  SKIP 3 (over else) [6]   = 9 bytes
        // else: digitalWrite(2,LOW)  [3]
        #expect(r.bytes == [
            0xF0, 0x7B, 0x13, 0x03,             // IF, op=greaterThan
            0x00, 0x00,                         //   operand a = reg 0
            0x01, 0x00, 0x04, 0x00, 0x00, 0x00, //   operand b = const 512
            0x09, 0x00,                         //   skip = 9 if false
            0xF7,
            0xF5, 0x02, 0x01,                   // then: digitalWrite(2, HIGH)
            0xF0, 0x7B, 0x14, 0x03, 0x00, 0xF7, // SKIP 3 (jump over else)
            0xF5, 0x02, 0x00,                   // else: digitalWrite(2, LOW)
        ])
    }

    @Test func ifWithoutElseHasNoTrailingSkip() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(1), .equal, .reg(2)) { $0.digitalWrite(pin: 5, value: true) }
        // IF op=0(equal) reg1 vs reg2, skip = 3 (just the then-block), no SKIP message
        #expect(r.bytes == [
            0xF0, 0x7B, 0x13, 0x00,   // IF equal
            0x00, 0x01,               //   a = reg 1
            0x00, 0x02,               //   b = reg 2
            0x03, 0x00,               //   skip = 3
            0xF7,
            0xF5, 0x05, 0x01,         // then: digitalWrite(5, HIGH)
        ])
    }

    @Test func nestedIfSkipCountsIncludeInnerBytes() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(0), .greaterThan, .const(0)) { t in
            t.ifTrue(.reg(1), .lessThan, .const(10)) { $0.digitalWrite(pin: 2, value: true) }
        }
        // Inner if (no else): IF message [15: hdr4 + a(reg,2) + b(const,6) + skip2 + F7]
        // + then digitalWrite [3] = 18 bytes. The outer if's skip must cover the
        // whole inner structure = 18.
        let b = r.bytes
        #expect(b[2] == 0x13)                    // outer IF
        // skip bytes are the 2 just before the outer IF's END_SYSEX
        let skipLo = b[b.firstIndex(of: 0xF7)! - 2]
        let skipHi = b[b.firstIndex(of: 0xF7)! - 1]
        #expect(Int(skipLo) | (Int(skipHi) << 7) == 18)
    }
}
