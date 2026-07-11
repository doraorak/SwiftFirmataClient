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

    @Test func loopOpEncodesBeginBodyEnd() {
        var r = FirmataTaskRecorder()
        r.repeat(times: 3, gap: .milliseconds(200)) { $0.digitalWrite(pin: .pin(5), high: true) }
        // LOOP_BEGIN(count=3, gap=200 -> 72|1<<7, skip=8 = body(3) + LOOP_END(5)); body; LOOP_END
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x34, 0x03, 0x00, 72, 0x01, 0x08, 0x00, 0xF7, // EXT LOOP
            0xF5, 0x05, 0x01,                                              // body: digitalWrite(5, HIGH)
            0xF0, 0x7B, 0x7F, 0x35, 0xF7,                                  // EXT LOOP_END
        ])
    }

    @Test func pwmConfigEncoding() {
        var r = FirmataTaskRecorder()
        r.configurePWM(pin: .pin(4), frequencyHz: 2000, resolutionBits: 8)
        // 2000 = 0x7D0 -> 7-bit LE limbs 0x50, 0x0F, 0x00
        #expect(r.bytes == [0xF0, 0x0E, 0x04, 0x50, 0x0F, 0x00, 0x08, 0xF7])
    }

    @Test func toneComposesConfigDutyDelayOff() {
        var r = FirmataTaskRecorder()
        r.tone(pin: .pin(4), hz: 440, duration: .milliseconds(100))

        var expected = FirmataTaskRecorder()
        expected.configurePWM(pin: .pin(4), frequencyHz: 440, resolutionBits: 8)
        expected.extendedAnalogWrite(pin: .pin(4), value: 128)
        expected.delay(.milliseconds(100))
        expected.extendedAnalogWrite(pin: .pin(4), value: 0)
        #expect(r.bytes == expected.bytes)
    }

    @Test func touchChannelsMapToSixThroughFifteen() {
        #expect(FirmataChannel.touch(0).number == 6)
        #expect(FirmataChannel.touch(9).number == 15)
        #expect(TaskChannel.touch(3).number == 9)
        #expect(PinMode.inputPulldown.rawValue == 0x10)
        #expect(PinMode.touch.rawValue == 0x11)
        #expect(PinMode.dac.rawValue == 0x12)
    }

    @Test func pwmFreqAndDelayOperandEncoding() {
        let r = FirmataTaskRecorder()
        r.configurePWM(pin: .pin(4), frequency: .reg(3))
        r.delay(TaskNumberRegister.reg(2))
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x36, 0x04, 0x00, 0x03, 0xF7,   // PWM_FREQ pin4 <reg 3>
            0xF0, 0x7B, 0x7F, 0x37, 0x00, 0x02, 0xF7,         // DELAY_OP <reg 2>
        ])
    }

    @Test func onceEncodesGuardSkipAndIndexes() {
        let r = FirmataTaskRecorder()
        r.once { $0.digitalWrite(pin: .pin(5), high: true) }
        r.once { $0.digitalWrite(pin: .pin(5), high: false) }
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x38, 0x00, 0x03, 0x00, 0xF7,   // ONCE idx 0, skip 3
            0xF5, 0x05, 0x01,
            0xF0, 0x7B, 0x7F, 0x38, 0x01, 0x03, 0x00, 0xF7,   // ONCE idx 1, skip 3
            0xF5, 0x05, 0x00,
        ])
    }

    @Test func onceIndexSurvivesNesting() {
        let r = FirmataTaskRecorder()
        r.repeat(times: 2) { o in
            o.once { $0.digitalWrite(pin: .pin(5), high: true) }   // idx 0 inside the branch
        }
        r.once { $0.digitalWrite(pin: .pin(5), high: false) }      // must be idx 1
        let tail = Array(r.bytes.suffix(11))
        #expect(tail[3] == 0x38 && tail[4] == 0x01)
    }

    @Test func toneOperandComposition() {
        let r = FirmataTaskRecorder()
        r.tone(pin: .pin(19), hz: .reg(4), duration: .number(200))
        let expected = FirmataTaskRecorder()
        expected.configurePWM(pin: .pin(19), frequency: .reg(4))
        expected.extendedAnalogWrite(pin: .pin(19), value: 128)
        expected.delay(TaskNumberLiteral(rawValue: 200))
        expected.extendedAnalogWrite(pin: .pin(19), value: 0)
        #expect(r.bytes == expected.bytes)
    }

    // Host-side simulation of the firmware scheduler's execute()+loopBegin/loopEnd over the real
    // recorder byte stream — proves the body fires exactly N times (incl. nesting / count 0), no board.
    @Test func loopVMFiresBodyExactlyNTimes() {
        func fires(_ count: Int, nested inner: Int? = nil) -> Int {
            var r = FirmataTaskRecorder()
            r.repeat(times: count, gap: .milliseconds(10)) { o in
                if let inner { o.repeat(times: inner, gap: .milliseconds(10)) { $0.digitalWrite(pin: .pin(5), high: true) } }
                else { o.digitalWrite(pin: .pin(5), high: true) }
            }
            return simulateLoop(r.bytes)
        }
        #expect(fires(4) == 4)
        #expect(fires(1) == 1)
        #expect(fires(0) == 0)
        #expect(fires(3, nested: 2) == 6)   // nested loops multiply
    }

    /// Faithful port of the firmware VM: walks the byte stream with a program counter and a loop
    /// stack; returns how many times the body message (digitalWrite, 0xF5) ran.
    private func simulateLoop(_ bytes: [UInt8]) -> Int {
        var pos = 0, fired = 0, steps = 0
        var remaining: [Int] = [], resume: [Int] = []
        while pos < bytes.count {
            steps += 1; if steps > 100_000 { break }                 // runaway guard
            if bytes[pos] == 0xF0 {                                   // SysEx frame F0…F7
                let end = bytes[pos...].firstIndex(of: 0xF7)!
                let f = Array(bytes[pos...end]); pos = end + 1
                if f.count >= 4, f[1] == 0x7B, f[2] == 0x7F, f[3] == 0x34 {        // LOOP_BEGIN
                    let count = Int(f[4]) | (Int(f[5]) << 7)
                    let skip  = Int(f[8]) | (Int(f[9]) << 7)
                    if count == 0 { pos += skip } else { remaining.append(count); resume.append(pos) }
                } else if f.count >= 4, f[1] == 0x7B, f[2] == 0x7F, f[3] == 0x35 { // LOOP_END
                    if !remaining.isEmpty {
                        remaining[remaining.count - 1] -= 1
                        if remaining.last! > 0 { pos = resume.last! }
                        else { remaining.removeLast(); resume.removeLast() }
                    }
                }                                                     // DELAY / other sysex: transparent
            } else if bytes[pos] == 0xF5 {                            // digitalWrite body (3 bytes)
                fired += 1; pos += 3
            } else { pos += 1 }
        }
        return fired
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
        let outer = r.analogRead(channel: .channel(0))            // -> R31 (internal auto, R31↓)
        var inner: (any TaskNumber)?
        r.ifTrue(outer, .greaterThan, .number(100)) {
            inner = $0.analogRead(channel: .channel(1))           // continues the cursor; must not reuse R31
        }
        let after = r.analogRead(channel: .channel(2))            // resumes past the branch's allocation
        #expect((outer as? any TaskRegister)?.index == 31)
        #expect((inner as? any TaskRegister)?.index == 30)        // distinct from outer
        #expect((after as? any TaskRegister)?.index == 29)
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
        var ints = [Int32](repeating: 0, count: 32); ints[3] = 1500; ints[15] = -7   // 32 int + 16 float wire layout
        var floats = [Float](repeating: 0, count: 16); floats[2] = 3.5
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
        let light = r.analogRead(channel: .channel(0))     // auto -> R31
        r.analogWrite(pin: .pin(4), value: light)          // PWM follows the reading
        #expect(Array(r.bytes.suffix(9)) == [0xF0, 0x7B, 0x7F, 0x32, 1, 4, 0x00, 31, 0xF7])
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
