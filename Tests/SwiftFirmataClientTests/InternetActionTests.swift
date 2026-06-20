import Testing
@testable import SwiftFirmataClient

// Internet actions + register-returning recorder reads (non-standard extension).
// HTTP ops ride the scheduler's reserved extension command: F0 7B 7F 15 … F7.
// "http://x" = [104,116,116,112,58,47,47,120] (8 bytes).
@Suite("InternetActions")
struct InternetActionTests {

    private let urlBytes: [UInt8] = [104, 116, 116, 112, 58, 47, 47, 120]  // "http://x"

    // MARK: - Recorder encoding

    @Test func httpGetEncoding() {
        var r = FirmataTaskRecorder()
        r.httpGet("http://x", statusInto: 0, valueInto: 1)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x15,
            0x00, 0x00, 0x01,          // method=GET, statusReg=0, valueReg=1
            0x08, 0x00,                // urlLen = 8
        ] + urlBytes + [
            0x00, 0x00,                // bodyLen = 0
            0xF7,
        ])
    }

    @Test func httpPostEncoding() {
        var r = FirmataTaskRecorder()
        r.httpPost("http://x", body: "hi", statusInto: 2, valueInto: 3)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x15,
            0x01, 0x02, 0x03,          // method=POST, statusReg=2, valueReg=3
            0x08, 0x00,                // urlLen = 8
        ] + urlBytes + [
            0x02, 0x00,                // bodyLen = 2
            104, 105,                  // "hi"
            0xF7,
        ])
    }

    // MARK: - Recorder register-returning reads (auto-allocate R15 → R0)

    @Test func recorderReadsReturnDescendingRegisters() {
        var r = FirmataTaskRecorder()
        let a = r.digitalRead(pin: 7)
        let b = r.analogRead(channel: 0)
        guard case .reg(let ra) = a, case .reg(let rb) = b else {
            Issue.record("Expected register operands"); return
        }
        #expect(ra == 15)   // first auto register
        #expect(rb == 14)   // next, descending
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x11, 15, 7, 0xF7,    // R15 = digitalRead(7)
            0xF0, 0x7B, 0x7F, 0x12, 14, 0, 0xF7,    // R14 = analogRead(A0)
        ])
    }

    @Test func recorderReadOperandFlowsIntoIfTrue() {
        var r = FirmataTaskRecorder()
        let dark = r.analogRead(channel: 0)                    // -> R15
        r.ifTrue(dark, .lessThan, .const(300)) { $0.digitalWrite(pin: 2, high: true) }
        // First the read op, then an EXT IF whose operand A is reg 15.
        #expect(Array(r.bytes.prefix(7)) == [0xF0, 0x7B, 0x7F, 0x12, 15, 0, 0xF7])
        let ifStart = 7
        #expect(r.bytes[ifStart + 3] == 0x13)                  // EXT IF
        #expect(r.bytes[ifStart + 5] == 0x00 && r.bytes[ifStart + 6] == 15)  // operand a = reg 15
    }

    // MARK: - Parser: HTTP_REPLY -> .httpResponse

    @Test func httpReplyParses() {
        var parser = FirmataParser()
        // F0 7B 0B status(200 -> 0x48,0x01) "OK" as 14-bit pairs F7
        let frame: [UInt8] = [0xF0, 0x7B, 0x0B, 0x48, 0x01, 79, 0, 75, 0, 0xF7]
        var result: FirmataMessage?
        for b in frame { if let m = parser.consume(b) { result = m } }
        guard case .httpResponse(let status, let body) = result else {
            Issue.record("Expected .httpResponse"); return
        }
        #expect(status == 200)
        #expect(body == "OK")
    }

    // MARK: - Live API

    private func makeClient() async -> (FirmataClient, MockTransport) {
        let transport = MockTransport()
        let client = FirmataClient(transport: transport)
        await client.connect()
        await Task.yield()
        return (client, transport)
    }

    @Test func liveHttpGetSendsOpAndReturnsResponse() async throws {
        let (client, transport) = await makeClient()
        async let resp = client.httpGet("http://x")
        await Task.yield()
        transport.injectHTTPResponse(status: 200, body: "hello")
        let r = try await resp
        #expect(r.status == 200)
        #expect(r.body == "hello")
        // Live requests default to status->R15, value->R14.
        #expect(transport.lastSent == [
            0xF0, 0x7B, 0x7F, 0x15, 0x00, 15, 14, 0x08, 0x00,
        ] + urlBytes + [0x00, 0x00, 0xF7])
    }

    @Test func liveHttpPostSendsBody() async throws {
        let (client, transport) = await makeClient()
        async let resp = client.httpPost("http://x", body: "hi")
        await Task.yield()
        transport.injectHTTPResponse(status: 201, body: "")
        let r = try await resp
        #expect(r.status == 201)
        #expect(transport.lastSent == [
            0xF0, 0x7B, 0x7F, 0x15, 0x01, 15, 14, 0x08, 0x00,
        ] + urlBytes + [0x02, 0x00, 104, 105, 0xF7])
    }
}
