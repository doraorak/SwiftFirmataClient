import Testing
@testable import SwiftFirmataClient

// MARK: - Firmata Scheduler tests

@Suite("Scheduler")
struct SchedulerTests {

    // MARK: Encoder7Bit

    @Test func encoder7BitRoundTrips() {
        for n in [0, 1, 2, 3, 5, 6, 7, 8, 14, 48, 100] {
            let input = (0..<n).map { UInt8(($0 * 37 + 11) & 0xFF) }
            let encoded = encode7BitFirmata(input)
            #expect(encoded.allSatisfy { $0 < 0x80 })          // 7-bit safe
            let decoded = decode7BitFirmata(num7BitOutBytes(encoded.count), encoded)
            #expect(decoded == input, "round-trip failed for n=\(n)")
        }
    }

    @Test func encoder7BitKnownVector() {
        // Verified byte-for-byte against the ESP32 firmware:
        // [F4 02 01 F5 02 01]  ->  [74 05 04 28 2F 20 00]
        let task: [UInt8] = [0xF4, 0x02, 0x01, 0xF5, 0x02, 0x01]
        #expect(encode7BitFirmata(task) == [0x74, 0x05, 0x04, 0x28, 0x2F, 0x20, 0x00])
    }

    @Test func timeEncoding() {
        // 1500 ms = 0x05DC -> LE [DC 05 00 00] -> 7-bit packed [5C 0B 00 00 00]
        #expect(timeBytes(1500) == [0xDC, 0x05, 0x00, 0x00])
        #expect(encode7BitFirmata(timeBytes(1500)) == [0x5C, 0x0B, 0x00, 0x00, 0x00])
    }

    // MARK: Recorder

    @Test func recorderBuildsLiveByteStream() {
        var r = FirmataTaskRecorder()
        r.setPinMode(2, mode: .output)
        r.digitalWrite(pin: 2, high: true)
        r.delay(.milliseconds(1500))
        r.digitalWrite(pin: 2, high: false)
        let delayMsg: [UInt8] = [0xF0, 0x7B, 0x03] + encode7BitFirmata(timeBytes(1500)) + [0xF7]
        var expected: [UInt8] = [0xF4, 2, 0x01, 0xF5, 2, 0x01]
        expected += delayMsg
        expected += [0xF5, 2, 0x00]
        #expect(r.bytes == expected)
    }

    // MARK: Low-level message framing

    private func makeClient() async -> (FirmataClient, MockTransport) {
        let t = MockTransport()
        let c = FirmataClient(transport: t)
        await c.connect()
        await Task.yield()
        return (c, t)
    }

    @Test func createTaskFraming() async throws {
        let (c, t) = await makeClient()
        try await c.createTask(id: 1, length: 6)
        #expect(t.lastSent == [0xF0, 0x7B, 0x00, 1, 0x06, 0x00, 0xF7])
    }

    @Test func deleteTaskFraming() async throws {
        let (c, t) = await makeClient()
        try await c.deleteTask(id: 3)
        #expect(t.lastSent == [0xF0, 0x7B, 0x01, 3, 0xF7])
    }

    @Test func addToTaskFraming() async throws {
        let (c, t) = await makeClient()
        try await c.addToTask(id: 1, data: [0xF4, 0x02, 0x01, 0xF5, 0x02, 0x01])
        #expect(t.lastSent == [0xF0, 0x7B, 0x02, 1, 0x74, 0x05, 0x04, 0x28, 0x2F, 0x20, 0x00, 0xF7])
    }

    @Test func scheduleTaskFraming() async throws {
        let (c, t) = await makeClient()
        try await c.scheduleTask(id: 1, delay: .milliseconds(1500))
        #expect(t.lastSent == [0xF0, 0x7B, 0x04, 1, 0x5C, 0x0B, 0x00, 0x00, 0x00, 0xF7])
    }

    @Test func resetTasksFraming() async throws {
        let (c, t) = await makeClient()
        try await c.resetTasks()
        #expect(t.lastSent == [0xF0, 0x7B, 0x07, 0xF7])
    }

    // MARK: High-level uploadTask

    /// Drives `uploadTask` to completion, satisfying its closing queryAllTasks
    /// round-trip (which the mock does not auto-answer).
    private func completeUpload(_ t: MockTransport, _ run: @escaping @Sendable () async throws -> Void) async throws {
        let task = Task { try await run() }
        for _ in 0..<100_000 {
            if t.sentBytes.last == [0xF0, 0x7B, 0x05, 0xF7] { break }   // queryAll was sent
            await Task.yield()
        }
        t.inject([0xF0, 0x7B, 0x09, 0xF7])   // empty task-list reply confirms receipt
        try await task.value
    }

    @Test func uploadTaskOneShotSequence() async throws {
        let (c, t) = await makeClient()
        try await completeUpload(t) {
            try await c.uploadTask(id: 1, startDelay: .zero) { task in
                task.setPinMode(2, mode: .output)
                task.digitalWrite(pin: 2, high: true)
            }
        }
        // delete, create(len=6), add, schedule, queryAll (confirmation)
        #expect(t.sentBytes.count == 5)
        #expect(t.sentBytes[0] == [0xF0, 0x7B, 0x01, 1, 0xF7])                 // delete
        #expect(t.sentBytes[1] == [0xF0, 0x7B, 0x00, 1, 0x06, 0x00, 0xF7])     // create len 6
        #expect(t.sentBytes[2] == [0xF0, 0x7B, 0x02, 1, 0x74, 0x05, 0x04, 0x28, 0x2F, 0x20, 0x00, 0xF7])
        #expect(t.sentBytes[3] == [0xF0, 0x7B, 0x04, 1, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]) // schedule +0
        #expect(t.sentBytes[4] == [0xF0, 0x7B, 0x05, 0xF7])                    // confirmation query
    }

    @Test func uploadTaskRepeatingAppendsTrailingDelay() async throws {
        let (c, t) = await makeClient()
        try await completeUpload(t) {
            try await c.uploadTask(id: 2, repeatEvery: .milliseconds(500)) { task in
                task.setPinMode(2, mode: .output)
                task.digitalWrite(pin: 2, high: true)
                task.delay(.milliseconds(500))
                task.digitalWrite(pin: 2, high: false)
            }
        }
        // The reserved length must equal the recorded bytes including BOTH the
        // in-sequence delay and the trailing repeat delay.
        var recorder = FirmataTaskRecorder()
        recorder.setPinMode(2, mode: .output)
        recorder.digitalWrite(pin: 2, high: true)
        recorder.delay(.milliseconds(500))
        recorder.digitalWrite(pin: 2, high: false)
        recorder.delay(.milliseconds(500))   // trailing -> loop
        let expectedLen = recorder.bytes.count

        let create = t.sentBytes[1]
        let len = Int(create[4]) | (Int(create[5]) << 7)
        #expect(create[2] == 0x00)                              // CREATE
        #expect(len == expectedLen)
        #expect(t.sentBytes[t.sentBytes.count - 2][2] == 0x04)  // SCHEDULE precedes the confirmation
        #expect(t.sentBytes.last == [0xF0, 0x7B, 0x05, 0xF7])   // confirmation query
    }

    // MARK: Reply parsing

    @Test func parseQueryAllReply() {
        var p = FirmataParser()
        let msgs = [0xF0, 0x7B, 0x09, 3, 7, 9, 0xF7].compactMap { p.consume(UInt8($0)) }
        guard case .schedulerTaskList(let ids) = msgs.first else {
            Issue.record("expected .schedulerTaskList, got \(msgs)"); return
        }
        #expect(ids == [3, 7, 9])
    }

    @Test func parseErrorReply() {
        var p = FirmataParser()
        let msgs = [0xF0, 0x7B, 0x08, 5, 0xF7].compactMap { p.consume(UInt8($0)) }
        guard case .schedulerError(let id) = msgs.first else {
            Issue.record("expected .schedulerError"); return
        }
        #expect(id == 5)
    }

    @Test func parseQueryTaskReplyRoundTrip() {
        // Build a reply the way the firmware does, then parse it back.
        let timeMs: UInt32 = 1000
        let data: [UInt8] = [0xAA, 0xBB, 0xCC]
        let length = data.count
        let position = 1
        var raw: [UInt8] = timeBytes(timeMs)
        raw += [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF)]
        raw += [UInt8(position & 0xFF), UInt8((position >> 8) & 0xFF)]
        raw += data
        let frame: [UInt8] = [0xF0, 0x7B, 0x0A, 5] + encode7BitFirmata(raw) + [0xF7]

        var p = FirmataParser()
        let msgs = frame.compactMap { p.consume($0) }
        guard case .schedulerTask(let task) = msgs.first else {
            Issue.record("expected .schedulerTask, got \(msgs)"); return
        }
        #expect(task.id == 5)
        #expect(task.timeMs == 1000)
        #expect(task.length == 3)
        #expect(task.position == 1)
        #expect(task.data == [0xAA, 0xBB, 0xCC])
    }

    // MARK: Queries through the client

    @Test func queryAllTasksResolves() async throws {
        let (c, t) = await makeClient()
        async let ids = c.queryAllTasks()
        await Task.yield()
        t.inject([0xF0, 0x7B, 0x09, 1, 2, 0xF7])
        let result = try await ids
        #expect(result == [1, 2])
        #expect(t.lastSent == [0xF0, 0x7B, 0x05, 0xF7])
    }

    @Test func queryTaskMissReturnsNil() async throws {
        let (c, t) = await makeClient()
        async let task = c.queryTask(id: 9)
        await Task.yield()
        t.inject([0xF0, 0x7B, 0x08, 9, 0xF7])   // ERROR reply for id 9
        let result = try await task
        #expect(result == nil)
        #expect(t.lastSent == [0xF0, 0x7B, 0x06, 9, 0xF7])
    }
}
