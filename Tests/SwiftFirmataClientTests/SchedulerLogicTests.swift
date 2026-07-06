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

// MARK: - Live registers & servo (firmware 2.8+)

@Suite("LiveRegistersServo")
struct LiveRegistersServoTests {
    private func makeClient() async -> (FirmataClient, MockTransport) {
        let t = MockTransport()
        let c = FirmataClient(transport: t)
        await c.connect()
        await Task.yield()
        return (c, t)
    }
    private func limbs(_ v: UInt32) -> [UInt8] { (0..<5).map { UInt8((v >> (7 * $0)) & 0x7F) } }

    @Test func setRegisterBytes() async throws {
        let (c, t) = await makeClient()
        try await c.setRegister(3, to: 1500)
        #expect(t.lastSent == [0xF0, 0x7B, 0x7F, 0x10, 3] + limbs(1500) + [0xF7])
        await #expect(throws: FirmataError.self) { try await c.setRegister(16, to: 0) }
    }

    @Test func setFloatRegisterBytes() async throws {
        let (c, t) = await makeClient()
        try await c.setFloatRegister(2, to: 3.5)
        #expect(t.lastSent == [0xF0, 0x7B, 0x7F, 0x1B, 2] + limbs(Float(3.5).bitPattern) + [0xF7])
    }

    @Test func queryRegistersRoundTrip() async throws {
        let (c, t) = await makeClient()
        async let snap = c.queryRegisters()
        await Task.yield()
        var ints = [Int32](repeating: 0, count: 16); ints[3] = 1500; ints[15] = -7
        var floats = [Float](repeating: 0, count: 8); floats[2] = 3.5
        var frame: [UInt8] = [0xF0, 0x7B, 0x0C]
        for v in ints   { frame += limbs(UInt32(bitPattern: v)) }
        for v in floats { frame += limbs(v.bitPattern) }
        frame.append(0xF7)
        t.inject(frame)
        let got = try await snap
        #expect(got.ints[3] == 1500 && got.ints[15] == -7 && got.floats[2] == 3.5)
        #expect(t.lastSent == [0xF0, 0x7B, 0x7F, 0x31, 0xF7])
    }

    @Test func servoBytes() async throws {
        let (c, t) = await makeClient()
        try await c.configureServo(pin: .pin(13), minPulseMicros: 600, maxPulseMicros: 2300)
        #expect(t.lastSent == [0xF0, 0x70, 13,
                               UInt8(600 & 0x7F), UInt8(600 >> 7),
                               UInt8(2300 & 0x7F), UInt8(2300 >> 7), 0xF7])
        try await c.servoWrite(pin: .pin(2), value: 90)                    // pin <= 15: analog message
        #expect(t.lastSent == [0xE2, 90, 0])
        try await c.servoWrite(pin: .pin(25), value: 1500)                 // pin > 15: extended analog
        #expect(t.lastSent?.prefix(3) == [0xF0, 0x6F, 25])
    }

    @Test func recorderServoWrite() {
        let r = FirmataTaskRecorder()
        r.servoWrite(pin: .pin(2), value: 90)
        #expect(r.bytes == [0xE2, 90, 0])
        r.servoWrite(pin: .pin(25), value: 1500)
        #expect(Array(r.bytes.dropFirst(3).prefix(3)) == [0xF0, 0x6F, 25])
    }
}

// MARK: - Operand-valued pin writes (firmware 2.9+)

@Suite("OperandWrites")
struct OperandWriteTests {
    @Test func operandWriteBytes() {
        let r = FirmataTaskRecorder()
        r.analogWrite(pin: .pin(4), value: .reg(5))
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x32, 1, 4, 0x00, 5, 0xF7])

        let r2 = FirmataTaskRecorder()
        r2.servoWrite(pin: .pin(13), value: .reg(6))
        #expect(r2.bytes == [0xF0, 0x7B, 0x7F, 0x32, 1, 13, 0x00, 6, 0xF7])

        let r3 = FirmataTaskRecorder()
        r3.digitalWrite(pin: .pin(2), high: .boolReg(3))
        #expect(r3.bytes == [0xF0, 0x7B, 0x7F, 0x32, 0, 2, 0x00, 3, 0xF7])
    }

    @Test func operandWriteFromTaskVariable() {
        let r = FirmataTaskRecorder()
        let light = r.analogRead(channel: .channel(0))     // auto -> R15
        r.analogWrite(pin: .pin(4), value: light)          // PWM follows the reading
        #expect(Array(r.bytes.suffix(9)) == [0xF0, 0x7B, 0x7F, 0x32, 1, 4, 0x00, 15, 0xF7])
    }
}

// MARK: - Module subsystem + IR module (firmware 2.9+)

@Suite("Modules")
struct ModuleTests {
    private func makeClient() async -> (FirmataClient, MockTransport) {
        let t = MockTransport()
        let c = FirmataClient(transport: t)
        await c.connect()
        await Task.yield()
        return (c, t)
    }

    @Test func queryModulesRoundTrip() async throws {
        let (c, t) = await makeClient()
        async let mods = c.queryModules()
        await Task.yield()
        // reply: one module — id 1, v1.0, name "ir"
        t.inject([0xF0, 0x0D, 0x7F, 1, 0x01, 1, 0, 2, 0x69, 0x72, 0xF7])
        let got = try await mods
        #expect(got == [ModuleInfo(id: 1, name: "ir", major: 1, minor: 0)])
        #expect(t.lastSent == [0xF0, 0x0D, 0x00, 0xF7])
    }

    // Generic module transport primitives (protocol-specific modules — e.g. the IR
    // module — live in their own packages and test their own byte formats).
    @Test func moduleOpBytes() async throws {
        let (c, t) = await makeClient()
        try await c.sendToModule(id: 0x42, payload: [1, 2, 3])
        #expect(t.lastSent == [0xF0, 0x0D, 0x42, 1, 2, 3, 0xF7])
        let r = FirmataTaskRecorder()
        r.moduleOp(id: 0x42, payload: [1, 2, 3])
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x42, 1, 2, 3, 0xF7])
    }

    @Test func moduleEventParses() {
        // Any first byte 0x01–0x7E is a module id; the parser surfaces it as a moduleEvent.
        var p = FirmataParser()
        let frame: [UInt8] = [0xF0, 0x0D, 0x05, 0x11, 0x22, 0xF7]
        let msgs = frame.compactMap { p.consume($0) }
        guard case let .moduleEvent(id, payload) = msgs.first else {
            Issue.record("expected moduleEvent, got \(msgs)"); return
        }
        #expect(id == 5)
        #expect(payload == [0x11, 0x22])
    }
}
