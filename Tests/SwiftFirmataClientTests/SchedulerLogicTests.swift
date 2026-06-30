import Testing
@testable import SwiftFirmataClient

@Suite("SchedulerLogic")
struct SchedulerLogicTests {

    // All logic ops ride the standard scheduler's reserved extension command
    // (0x7F, EXTENDED_SCHEDULER_COMMAND): F0 7B 7F <ext-subcmd> … F7.

    @Test func setRegisterEncoding() {
        var r = FirmataTaskRecorder()
        r.setRegister(.reg(3), to: .number(512))
        // F0 7B 7F 10 reg=3 <512 as Encoder7Bit of [0,2,0,0] = 0,4,0,0,0> F7
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x10, 0x03, 0x00, 0x04, 0x00, 0x00, 0x00, 0xF7])
    }

    @Test func readDigitalAndAnalogEncoding() {
        var r = FirmataTaskRecorder()
        r.digitalRead(into: .boolReg(1), pin: .pin(7))
        r.analogRead(into: .reg(2), channel: .channel(0))
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x11, 0x01, 0x07, 0xF7,   // R1 = digitalRead(7)
            0xF0, 0x7B, 0x7F, 0x12, 0x02, 0x00, 0xF7,   // R2 = analogRead(A0)
        ])
    }

    @Test func ifElseLaysOutSkipsCorrectly() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(0), .greaterThan, .number(512),
            then:   { $0.digitalWrite(pin: .pin(2), high: true) },
            elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })

        // IF (op=3 greaterThan) reg0 vs const512, skip=10 (then-block + trailing SKIP)
        // then: digitalWrite(2,HIGH) [3]  +  SKIP 3 (over else) [7]   = 10 bytes
        // else: digitalWrite(2,LOW)  [3]
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x13, 0x03,       // EXT IF, op=greaterThan
            0x00, 0x00,                         //   operand a = reg 0
            0x01, 0x00, 0x04, 0x00, 0x00, 0x00, //   operand b = const 512
            0x0A, 0x00,                         //   skip = 10 if false
            0xF7,
            0xF5, 0x02, 0x01,                   // then: digitalWrite(2, HIGH)
            0xF0, 0x7B, 0x7F, 0x14, 0x03, 0x00, 0xF7, // EXT SKIP 3 (jump over else)
            0xF5, 0x02, 0x00,                   // else: digitalWrite(2, LOW)
        ])
    }

    @Test func ifWithoutElseHasNoTrailingSkip() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(1), .equal, .reg(2)) { $0.digitalWrite(pin: .pin(5), high: true) }
        // IF op=0(equal) reg1 vs reg2, skip = 3 (just the then-block), no SKIP message
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x13, 0x00,   // EXT IF equal
            0x00, 0x01,                     //   a = reg 1
            0x00, 0x02,                     //   b = reg 2
            0x03, 0x00,                     //   skip = 3
            0xF7,
            0xF5, 0x05, 0x01,               // then: digitalWrite(5, HIGH)
        ])
    }

    @Test func compareEncodesOpDstThenOperands() {
        var r = FirmataTaskRecorder()
        let isUp = r.compare(.reg(0), .greaterThan, .number(0), into: .boolReg(5))
        // EXT CMP (0x27) op=greaterThan(3) dst=R5, a=reg0, b=const0
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x27, 0x03, 0x05,   // CMP op=greaterThan dst=R5
            0x00, 0x00,                           //   a = reg 0
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,   //   b = const 0
            0xF7,
        ])
        #expect(isUp.index == 5)
    }

    @Test func ifTrueTaskBoolLowersToNotEqualZero() {
        // The TaskBool overload is sugar for `ifTrue(cond, .notEqual, .number(0))`.
        var explicit = FirmataTaskRecorder()
        explicit.ifTrue(.reg(3), .notEqual, .number(0),
            then:   { $0.digitalWrite(pin: .pin(2), high: true) },
            elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })

        var sugar = FirmataTaskRecorder()
        sugar.ifTrue(.boolReg(3),
            then:   { $0.digitalWrite(pin: .pin(2), high: true) },
            elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })

        #expect(sugar.bytes == explicit.bytes)
    }

    @Test func nestedIfSkipCountsIncludeInnerBytes() {
        var r = FirmataTaskRecorder()
        r.ifTrue(.reg(0), .greaterThan, .number(0)) { t in
            t.ifTrue(.reg(1), .lessThan, .number(10)) { $0.digitalWrite(pin: .pin(2), high: true) }
        }
        // Inner if (no else): IF message [16: F0 7B 7F 13 op + a(reg,2) + b(const,6)
        // + skip2 + F7] + then digitalWrite [3] = 19 bytes. The outer if's skip must
        // cover the whole inner structure = 19.
        let b = r.bytes
        #expect(b[2] == 0x7F && b[3] == 0x13)    // outer EXT IF
        let skipLo = b[b.firstIndex(of: 0xF7)! - 2]
        let skipHi = b[b.firstIndex(of: 0xF7)! - 1]
        #expect(Int(skipLo) | (Int(skipHi) << 7) == 19)
    }

    // Registers/slots are global on the device. A nested branch must continue the
    // parent's auto-allocation cursor (not reset to R15), so it never reuses a
    // register the outer scope is still holding — and the outer scope resumes past
    // whatever the branch allocated.
    @Test func nestedBranchAllocationDoesNotClobberOuter() {
        let r = FirmataTaskRecorder()
        let outer = r.analogRead(channel: .channel(0))            // -> R15
        var inner: (any TaskNumber)?
        r.ifTrue(outer, .greaterThan, .number(100)) {
            inner = $0.analogRead(channel: .channel(1))           // continues the cursor; must not reuse R15
        }
        let after = r.analogRead(channel: .channel(2))            // resumes past the branch's allocation
        #expect((outer as? any TaskRegister)?.index == 15)
        #expect((inner as? any TaskRegister)?.index == 14)        // distinct from outer (was 15 before the fix)
        #expect((after as? any TaskRegister)?.index == 13)
    }
}
