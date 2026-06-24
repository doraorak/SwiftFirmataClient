import Testing
@testable import SwiftFirmataClient

// Internet actions + response-inspection ops (non-standard extension).
// HTTP ops ride the scheduler's reserved extension command: F0 7B 7F <op> … F7.
// "http://x" = [104,116,116,112,58,47,47,120] (8 bytes).
@Suite("InternetActions")
struct InternetActionTests {

    private let urlBytes: [UInt8] = [104, 116, 116, 112, 58, 47, 47, 120]  // "http://x"

    // MARK: - Recorder HTTP encoding (status-only; no value register)

    // httpGet/httpPost also emit a BODY_GEN op (capture generation -> gen reg R0, bottom-up).
    private let bodyGen0: [UInt8] = [0xF0, 0x7B, 0x7F, 0x22, 0, 0xF7]

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
        ] + bodyGen0)
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
        ] + bodyGen0)
    }

    // MARK: - Response-inspection op encoding

    @Test func jsonNumberAutoRegisters() {
        var r = FirmataTaskRecorder()
        let v = r.jsonNumber("id", scaledBy: 2)   // dst auto=15, found auto=14
        guard let rv = v.register else { Issue.record("expected reg"); return }
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
        guard let rv = v.register else { Issue.record("expected reg"); return }
        #expect(rv == 3)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x16, 3, 4, 0, 0x01, 0x00, 97, 0xF7,
        ])
    }

    @Test func bodyContainsEncoding() {
        var r = FirmataTaskRecorder()
        let b = r.bodyContains("OK")   // auto dst=15
        guard let rb = b.register else { Issue.record("expected reg"); return }
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

    // MARK: - Arithmetic encoding

    @Test func arithRegConstEncoding() {
        var r = FirmataTaskRecorder()
        let sum = r.add(.reg(0), .number(5), into: 3)
        guard let rd = sum.register else { Issue.record("expected reg"); return }
        #expect(rd == 3)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x1A,
            0x00, 0x03,                // op=add, dst=3
            0x00, 0x00,                // operand A: reg 0
            0x01, 5, 0, 0, 0, 0,       // operand B: const 5 (Encoder7Bit of [5,0,0,0])
            0xF7,
        ])
    }

    @Test func arithSubopsAndRegReg() {
        for (subop, build): (UInt8, (inout FirmataTaskRecorder) -> Void) in [
            (0, { _ = $0.add(.reg(1), .reg(2), into: 4) }),
            (1, { _ = $0.subtract(.reg(1), .reg(2), into: 4) }),
            (2, { _ = $0.multiply(.reg(1), .reg(2), into: 4) }),
            (3, { _ = $0.divide(.reg(1), .reg(2), into: 4) }),
            (4, { _ = $0.modulo(.reg(1), .reg(2), into: 4) }),
        ] {
            var r = FirmataTaskRecorder(); build(&r)
            #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x1A, subop, 0x04, 0x00, 0x01, 0x00, 0x02, 0xF7])
        }
    }

    @Test func arithAutoAllocatesDescending() {
        var r = FirmataTaskRecorder()
        let a = r.add(.reg(0), .reg(1))        // -> R15
        let b = r.multiply(.reg(0), .reg(1))   // -> R14
        guard let ra = a.register, let rb = b.register else { Issue.record("reg"); return }
        #expect(ra == 15)
        #expect(rb == 14)
    }

    // MARK: - Float registers / arithmetic / jsonFloat

    @Test func setFloatEncoding() {
        var r = FirmataTaskRecorder()
        let f = r.setFloatRegister(2, to: 1.5)
        guard let rf = f.register else { Issue.record("expected freg"); return }
        #expect(rf == 2)
        let bits = Float(1.5).bitPattern
        let expected: [UInt8] = [0xF0, 0x7B, 0x7F, 0x1B, 2]
            + encode7BitFirmata(timeBytes(bits)) + [0xF7]
        #expect(r.bytes == expected)
    }

    @Test func floatOperandBytes() {
        var r = FirmataTaskRecorder()
        _ = r.addFloat(.freg(0), .float(10.0), into: 1)
        let expected: [UInt8] = [0xF0, 0x7B, 0x7F, 0x1C, 0x00, 0x01,
                                 2, 0x00]                                 // operand A: freg 0
            + [3] + encode7BitFirmata(timeBytes(Float(10.0).bitPattern))  // operand B: fconst 10.0
            + [0xF7]
        #expect(r.bytes == expected)
    }

    @Test func floatArithSubopsAndAutoAlloc() {
        for (subop, build): (UInt8, (inout FirmataTaskRecorder) -> Void) in [
            (0, { _ = $0.addFloat(.freg(0), .freg(1), into: 2) }),
            (1, { _ = $0.subtractFloat(.freg(0), .freg(1), into: 2) }),
            (2, { _ = $0.multiplyFloat(.freg(0), .freg(1), into: 2) }),
            (3, { _ = $0.divideFloat(.freg(0), .freg(1), into: 2) }),
        ] {
            var r = FirmataTaskRecorder(); build(&r)
            #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x1C, subop, 0x02, 2, 0x00, 2, 0x01, 0xF7])
        }
        var r = FirmataTaskRecorder()
        let a = r.addFloat(.freg(0), .freg(1))       // -> F7
        let b = r.multiplyFloat(.freg(0), .freg(1))  // -> F6
        guard let ra = a.register, let rb = b.register else { Issue.record("freg"); return }
        #expect(ra == 7)
        #expect(rb == 6)
    }

    @Test func jsonFloatEncoding() {
        var r = FirmataTaskRecorder()
        let v = r.jsonFloat("p", into: 1, found: 2)
        guard let rf = v.register else { Issue.record("expected freg"); return }
        #expect(rf == 1)
        #expect(r.bytes == [
            0xF0, 0x7B, 0x7F, 0x1D, 1, 2,   // fdst=1, found=2
            0x01, 0x00, 112,                // path "p"
            0xF7,
        ])
    }

    // MARK: - Query ops (jsonType / jsonSize / stringLength / heapStats)

    @Test func queryOpEncoding() {
        for (op, build): (UInt8, (inout FirmataTaskRecorder) -> Void) in [
            (0x1E, { _ = $0.jsonType("p", into: 3) }),
            (0x1F, { _ = $0.jsonSize("p", into: 3) }),
            (0x20, { _ = $0.stringLength("p", into: 3) }),
        ] {
            var r = FirmataTaskRecorder(); build(&r)
            #expect(r.bytes == [0xF0, 0x7B, 0x7F, op, 3, 0x01, 0x00, 112, 0xF7])
        }
    }

    @Test func heapStatsEncoding() {
        var r = FirmataTaskRecorder()
        let (f, l) = r.heapStats(freeInto: 0, largestInto: 1)
        guard let rf = f.register, let rl = l.register else { Issue.record("reg"); return }
        #expect(rf == 0 && rl == 1)
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x21, 0, 1, 0xF7])
    }

    @Test func jsonTypeRawValues() {
        #expect(TaskJSONValueType.number.rawValue == 4)
        #expect(TaskJSONValueType.string.rawValue == 3)
        #expect(TaskJSONValueType.missing.rawValue == 0)
    }

    // MARK: - httpGet returns a TaskHTTPResponse handle (status auto-allocated)

    // MARK: - Recorder I2C (drive an I2C device from a task)

    @Test func i2cRecorderEncoding() {
        var r = FirmataTaskRecorder()
        r.i2cConfig()
        #expect(r.bytes == [0xF0, 0x78, 0x00, 0x00, 0xF7])
        var w = FirmataTaskRecorder()
        w.i2cWrite(address: 0x3C, data: [0x00, 0xAE])   // SSD1306 @0x3C: control 0x00, cmd 0xAE
        #expect(w.bytes == [
            0xF0, 0x76, 0x3C, 0x00,    // i2cRequest, addr=0x3C, control=0 (write, 7-bit)
            0x00, 0x00,                // 0x00 -> [lo,hi]
            0x2E, 0x01,                // 0xAE -> [0x2E, 0x01]
            0xF7,
        ])
    }

    @Test func httpGetReturnsHandleAutoAllocatingStatus() {
        var r = FirmataTaskRecorder()
        let a = r.httpGet("http://x")          // status auto -> R15
        let b = r.httpGet("http://x")          // status auto -> R14
        guard let ra = a.status.register, let rb = b.status.register else {
            Issue.record("expected status reg"); return
        }
        #expect(ra == 15)
        #expect(rb == 14)
        // explicit statusInto still works and is reflected in the handle
        var r2 = FirmataTaskRecorder()
        let c = r2.httpGet("http://x", statusInto: 3)
        guard let rc = c.status.register else { Issue.record("reg"); return }
        #expect(rc == 3)
        #expect(r2.bytes == [
            0xF0, 0x7B, 0x7F, 0x15, 0x00, 3, 0x08, 0x00,
        ] + urlBytes + [0x00, 0x00, 0xF7] + bodyGen0)
    }

    // MARK: - Handle ops: snapshot (in-place) / free

    @Test func snapshotUpgradesHandleInPlaceThenFree() {
        let r = FirmataTaskRecorder()
        let a = r.httpGet("http://x")        // borrowed handle (status R15, gen R0)
        r.snapshot(a.body)                   // in-place upgrade -> owns slot 0
        #expect(a.body.snapshotSlot == 0)
        r.free(a.body)
        let expectedTail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x23, 0, 0, 0, 0xF7] +   // snapshot slot 0, whole body
            [0xF0, 0x7B, 0x7F, 0x25, 0, 0xF7]           // free slot 0
        #expect(Array(r.bytes.suffix(expectedTail.count)) == expectedTail)
    }

    @Test func isValidEmitsRequestCountThenCompare() {
        let r = FirmataTaskRecorder()
        let resp = r.httpGet("http://x")     // status R15, gen R0
        let fresh = resp.body.isValid()      // R14 = requestCount; R13 = (R0 == R14)
        #expect(fresh.register == 13)
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x22, 14, 0xF7] +                            // REQUEST_COUNT -> R14
            [0xF0, 0x7B, 0x7F, 0x27, 0x00, 13, 0x00, 0x00, 0x00, 14, 0xF7]  // CMP equal R13 = (R0 == R14)
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    @Test func isValidOnOwnedSnapshotIsConstTrue() {
        let r = FirmataTaskRecorder()
        let resp = r.httpGet("http://x")
        r.json.snapshot(resp.body)           // owned -> always valid
        let v = resp.body.isValid()
        #expect(v.register == nil)           // a literal true, not a register read
    }

    @Test func taskResultStatusRawValues() {
        #expect(TaskResultStatus.ok.rawValue == 0)
        #expect(TaskResultStatus.stale.rawValue == 2)
        #expect(TaskResultStatus.allocFailed.rawValue == 5)
    }

    // MARK: - board.json namespace (selects the handle's source, then inspects)

    @Test func jsonNamespaceSelectsLiveThenInspects() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")                 // borrowed; generation captured in R0
        let v = r.json.number(h.body, "id", into: 7, found: 8)
        guard let rv = v.register, rv == 7 else { Issue.record("reg"); return }
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x24, 0x00, 0x00, 0xF7] +              // SELECT live, gen R0
            [0xF0, 0x7B, 0x7F, 0x16, 7, 8, 0, 0x02, 0x00, 105, 100, 0xF7]  // JSON_NUM "id" -> R7
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    @Test func jsonNamespaceSnapshotSelectsSnapshot() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        r.json.snapshot(h.body)                       // in-place -> owns slot 0
        #expect(h.body.snapshotSlot == 0)
        _ = r.json.number(h.body, "id", into: 7, found: 8)
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x24, 0x01, 0x00, 0xF7] +             // SELECT snapshot (sel = 1)
            [0xF0, 0x7B, 0x7F, 0x16, 7, 8, 0, 0x02, 0x00, 105, 100, 0xF7]
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    // MARK: - Inspection operands flow into ifTrue / auto-register descent

    @Test func jsonNumberFlowsIntoIfTrue() {
        var r = FirmataTaskRecorder()
        r.httpGet("http://x", statusInto: 0)
        let pct = r.jsonNumber("changePercent", scaledBy: 2)   // dst=15, found=14
        guard let rv = pct.register else { Issue.record("expected reg"); return }
        #expect(rv == 15)
        r.ifTrue(pct, .greaterThan, .number(0)) { $0.digitalWrite(pin: 2, high: true) }
        // The next auto-allocated read should be R13 (15 and 14 already taken).
        let nxt = r.bodyContains("x")
        guard let rn = nxt.register else { Issue.record("expected reg"); return }
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
