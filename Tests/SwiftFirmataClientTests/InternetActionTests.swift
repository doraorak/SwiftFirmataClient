import Testing
@testable import SwiftFirmataClient

// Internet actions + response-inspection ops (non-standard extension).
// HTTP ops ride the scheduler's reserved extension command: F0 7B 7F <op> … F7.
// "http://x" = [104,116,116,112,58,47,47,120] (8 bytes).
@Suite("InternetActions")
struct InternetActionTests {

    private let urlBytes: [UInt8] = [104, 116, 116, 112, 58, 47, 47, 120]  // "http://x"

    // MARK: - Recorder HTTP encoding (status-only; no value register)

    @Test func httpGetEncoding() {
        var r = FirmataTaskRecorder()
        r.httpGet("http://x", statusInto: 0)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x15,
            0x00, 0x00,                // method=GET, statusReg=0
            0x08, 0x00,                // urlLen = 8
        ] + urlBytes + [
            0x00, 0x00,                // bodyLen = 0
            0xF7,
        ])
    }

    @Test func httpPostEncoding() {
        var r = FirmataTaskRecorder()
        r.httpPost("http://x", body: "hi", statusInto: 2)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x15,
            0x01, 0x02,                // method=POST, statusReg=2
            0x08, 0x00,                // urlLen = 8
        ] + urlBytes + [
            0x02, 0x00,                // bodyLen = 2
            104, 105,                  // "hi"
            0xF7,
        ])
    }

    // MARK: - Response-inspection op encoding

    @Test func jsonNumberAutoRegisters() {
        var r = FirmataTaskRecorder()
        let v = r.jsonNumber("id", scaledBy: 2)   // dst auto=15, found auto=14
        guard case .reg(let rv) = v else { Issue.record("expected reg"); return }
        #expect(rv == 15)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x16,
            15, 14, 2,                 // dst=15, found=14, scale=2
            0x02, 0x00, 105, 100,      // path "id"
            0xF7,
        ])
    }

    @Test func jsonNumberExplicitRegisters() {
        var r = FirmataTaskRecorder()
        let v = r.jsonNumber("a", into: 3, found: 4)   // scale defaults to 0
        guard case .reg(let rv) = v else { Issue.record("expected reg"); return }
        #expect(rv == 3)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x16, 3, 4, 0, 0x01, 0x00, 97, 0xF7,
        ])
    }

    @Test func bodyContainsEncoding() {
        var r = FirmataTaskRecorder()
        let b = r.bodyContains("OK")   // auto dst=15
        guard case .reg(let rb) = b else { Issue.record("expected reg"); return }
        #expect(rb == 15)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x18, 15, 0x02, 0x00, 79, 75, 0xF7,
        ])
    }

    @Test func jsonStringEqualsEncoding() {
        var r = FirmataTaskRecorder()
        _ = r.jsonStringEquals("s", "hi", into: 5)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x17, 5,
            0x01, 0x00, 115,           // path "s"
            0x02, 0x00, 104, 105,      // value "hi"
            0xF7,
        ])
    }

    @Test func jsonStringContainsEncoding() {
        var r = FirmataTaskRecorder()
        _ = r.jsonStringContains("s", "h", into: 6)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x19, 6,
            0x01, 0x00, 115,           // path "s"
            0x01, 0x00, 104,           // substring "h"
            0xF7,
        ])
    }

    // MARK: - Inspection operands flow into ifTrue / auto-register descent

    @Test func jsonNumberFlowsIntoIfTrue() {
        var r = FirmataTaskRecorder()
        r.httpGet("http://x", statusInto: 0)
        let pct = r.jsonNumber("changePercent", scaledBy: 2)   // dst=15, found=14
        guard case .reg(let rv) = pct else { Issue.record("expected reg"); return }
        #expect(rv == 15)
        r.ifTrue(pct, .greaterThan, .const(0)) { $0.digitalWrite(pin: 2, high: true) }
        // The next auto-allocated read should be R13 (15 and 14 already taken).
        let nxt = r.bodyContains("x")
        guard case .reg(let rn) = nxt else { Issue.record("expected reg"); return }
        #expect(rn == 13)
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

    // MARK: - Host-side Foundation inspection of HTTPResponse

    @Test func httpResponseDecodesJSON() throws {
        let resp = HTTPResponse(status: 200, body: #"{"price": 12.5, "sym": "SPY"}"#)
        struct Quote: Decodable { let price: Double; let sym: String }
        let q = try resp.decode(Quote.self)
        #expect(q.price == 12.5)
        #expect(q.sym == "SPY")
        let obj = try resp.json() as? [String: Any]
        #expect(obj?["sym"] as? String == "SPY")
        #expect(resp.isSuccess)
    }

    @Test func httpResponseNonSuccess() {
        #expect(!HTTPResponse(status: 404, body: "").isSuccess)
        #expect(!HTTPResponse(status: 0, body: "").isSuccess)
    }

    // MARK: - Live API (status -> R15; body inspected on the host)

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
        // Live requests put status in R15 (no value register any more).
        #expect(transport.lastSent == [
            0xF0, 0x7B, 0x7F, 0x15, 0x00, 15, 0x08, 0x00,
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
            0xF0, 0x7B, 0x7F, 0x15, 0x01, 15, 0x08, 0x00,
        ] + urlBytes + [0x02, 0x00, 104, 105, 0xF7])
    }
}
