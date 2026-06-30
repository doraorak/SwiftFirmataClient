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
        r.httpGet("http://x", statusInto: .reg(0))
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
        r.httpPost("http://x", body: "hi", statusInto: .reg(2))
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

    @Test func jsonNumberEncoding() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        let v = r.json.getNumber(h.body, "id", scaledBy: 2, into: .reg(15), found: .reg(14))
        #expect(v.index == 15)
        #expect(Array(r.bytes.suffix(12)) == [   // the JSON_NUM op (after SELECT live)
            0xF0, 0x7B, 0x7F, 0x16, 15, 14, 2, 0x02, 0x00, 105, 100, 0xF7,
        ])
    }

    @Test func jsonNumberExplicitRegisters() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        let v = r.json.getNumber(h.body, "a", into: .reg(3), found: .reg(4))   // scale defaults to 0
        #expect(v.index == 3)
        #expect(Array(r.bytes.suffix(11)) == [
            0xF0, 0x7B, 0x7F, 0x16, 3, 4, 0, 0x01, 0x00, 97, 0xF7,
        ])
    }

    @Test func bodyContainsEncoding() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        let b = r.json.bodyContains(h.body, "OK", into: .boolReg(15))
        #expect(b.index == 15)
        #expect(Array(r.bytes.suffix(10)) == [
            0xF0, 0x7B, 0x7F, 0x18, 15, 0x02, 0x00, 79, 75, 0xF7,
        ])
    }

    // MARK: - Arithmetic encoding

    @Test func arithRegConstEncoding() {
        var r = FirmataTaskRecorder()
        let sum = r.add(.reg(0), .number(5), into: .reg(3))
        #expect(sum.index == 3)
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
            (0, { _ = $0.add(.reg(1), .reg(2), into: .reg(4)) }),
            (1, { _ = $0.subtract(.reg(1), .reg(2), into: .reg(4)) }),
            (2, { _ = $0.multiply(.reg(1), .reg(2), into: .reg(4)) }),
            (3, { _ = $0.divide(.reg(1), .reg(2), into: .reg(4)) }),
            (4, { _ = $0.modulo(.reg(1), .reg(2), into: .reg(4)) }),
        ] {
            var r = FirmataTaskRecorder(); build(&r)
            #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x1A, subop, 0x04, 0x00, 0x01, 0x00, 0x02, 0xF7])
        }
    }

    @Test func arithAutoAllocatesDescending() {
        var r = FirmataTaskRecorder()
        let a = r.add(.reg(0), .reg(1))        // -> R15
        let b = r.multiply(.reg(0), .reg(1))   // -> R14
        #expect(a.index == 15)
        #expect(b.index == 14)
    }

    // MARK: - Float registers / arithmetic / jsonFloat

    @Test func setFloatEncoding() {
        let r = FirmataTaskRecorder()
        r.setFloatRegister(.freg(2), to: .float(1.5))
        let bits = Float(1.5).bitPattern
        let expected: [UInt8] = [0xF0, 0x7B, 0x7F, 0x1B, 2]
            + encode7BitFirmata(timeBytes(bits)) + [0xF7]
        #expect(r.bytes == expected)
    }

    @Test func floatOperandBytes() {
        var r = FirmataTaskRecorder()
        _ = r.addFloat(.freg(0), .float(10.0), into: .freg(1))
        let expected: [UInt8] = [0xF0, 0x7B, 0x7F, 0x1C, 0x00, 0x01,
                                 2, 0x00]                                 // operand A: freg 0
            + [3] + encode7BitFirmata(timeBytes(Float(10.0).bitPattern))  // operand B: fconst 10.0
            + [0xF7]
        #expect(r.bytes == expected)
    }

    @Test func floatArithSubopsAndAutoAlloc() {
        for (subop, build): (UInt8, (inout FirmataTaskRecorder) -> Void) in [
            (0, { _ = $0.addFloat(.freg(0), .freg(1), into: .freg(2)) }),
            (1, { _ = $0.subtractFloat(.freg(0), .freg(1), into: .freg(2)) }),
            (2, { _ = $0.multiplyFloat(.freg(0), .freg(1), into: .freg(2)) }),
            (3, { _ = $0.divideFloat(.freg(0), .freg(1), into: .freg(2)) }),
        ] {
            var r = FirmataTaskRecorder(); build(&r)
            #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x1C, subop, 0x02, 2, 0x00, 2, 0x01, 0xF7])
        }
        var r = FirmataTaskRecorder()
        let a = r.addFloat(.freg(0), .freg(1))       // -> F7
        let b = r.multiplyFloat(.freg(0), .freg(1))  // -> F6
        #expect(a.index == 7)
        #expect(b.index == 6)
    }

    @Test func jsonFloatEncoding() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        let v = r.json.getFloat(h.body, "p", into: .freg(1), found: .reg(2))
        #expect(v.index == 1)
        #expect(Array(r.bytes.suffix(10)) == [
            0xF0, 0x7B, 0x7F, 0x1D, 1, 2, 0x01, 0x00, 112, 0xF7,   // JSON_FLOAT (after SELECT live)
        ])
    }

    // MARK: - Query ops (jsonType / jsonSize / heapStats)

    @Test func queryOpEncoding() {
        for (op, build): (UInt8, (FirmataTaskRecorder, TaskResponseBody) -> Void) in [
            (0x1E, { _ = $0.json.getType($1, "p", into: .reg(3)) }),
            (0x1F, { _ = $0.json.getSize($1, "p", into: .reg(3)) }),
        ] {
            let r = FirmataTaskRecorder(); let h = r.httpGet("http://x"); build(r, h.body)
            #expect(Array(r.bytes.suffix(9)) == [0xF0, 0x7B, 0x7F, op, 3, 0x01, 0x00, 112, 0xF7])
        }
    }

    @Test func getStringEncoding() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        let s = r.json.getString(h.body, "p")             // 0x2C slot pathLo pathHi path…
        #expect(s.slot.index == 0)                         // string slot 0 → firmware slot 2
        #expect(Array(r.bytes.suffix(9)) == [0xF0, 0x7B, 0x7F, 0x2C, 2, 0x01, 0x00, 112, 0xF7])
    }

    @Test func createStringEncoding() {
        let r = FirmataTaskRecorder()
        let s = r.string.createString("hi")               // 0x2D slot strLo strHi str… (literal -> slot)
        #expect(s.slot.index == 0)                         // string slot 0 → firmware slot 2
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x2D, 2, 0x02, 0x00, 104, 105, 0xF7])
    }

    @Test func changeSlotEncoding() {
        let r = FirmataTaskRecorder()
        let s = r.string.createString("hi")               // string slot 0 (fw 2)
        s.changeSlot(TaskStringSlot(3))                        // copy fw 2 -> fw 5, rebind
        #expect(s.slot.index == 3)
        #expect(Array(r.bytes.suffix(7)) == [0xF0, 0x7B, 0x7F, 0x2E, 5, 2, 0xF7])  // COPY_SLOT dst=5 src=2
    }

    @Test func heapStatsEncoding() {
        var r = FirmataTaskRecorder()
        let (f, l) = r.heapStats(freeInto: .reg(0), largestInto: .reg(1))
        #expect(f.index == 0 && l.index == 1)
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
        r.configureI2C()
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
        #expect(a.status.index == 15)
        #expect(b.status.index == 14)
        // explicit statusInto still works and is reflected in the handle
        var r2 = FirmataTaskRecorder()
        let c = r2.httpGet("http://x", statusInto: .reg(3))
        #expect(c.status.index == 3)
        #expect(r2.bytes == [
            0xF0, 0x7B, 0x7F, 0x15, 0x00, 3, 0x08, 0x00,
        ] + urlBytes + [0x00, 0x00, 0xF7] + bodyGen0)
    }

    // MARK: - Handle ops: snapshot (in-place) / free

    @Test func snapshotUpgradesHandleInPlaceThenFree() {
        let r = FirmataTaskRecorder()
        let a = r.httpGet("http://x")        // borrowed handle (status R15, gen R0)
        r.json.snapshot(a.body)               // in-place upgrade -> owns JSON slot 0
        #expect(a.body.snapshotSlot?.index == 0)
        r.json.free(a.body)
        let expectedTail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x23, 0, 0, 0, 0xF7] +   // snapshot slot 0, whole body
            [0xF0, 0x7B, 0x7F, 0x25, 0, 0xF7]           // free slot 0
        #expect(Array(r.bytes.suffix(expectedTail.count)) == expectedTail)
    }

    @Test func isValidEmitsRequestCountThenCompare() {
        let r = FirmataTaskRecorder()
        let resp = r.httpGet("http://x")     // status R15, gen R0
        let fresh = resp.body.isValid()      // R14 = requestCount; R13 = (R0 == R14)
        #expect(fresh.index == 13)
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x22, 14, 0xF7] +                            // REQUEST_COUNT -> R14
            [0xF0, 0x7B, 0x7F, 0x27, 0x00, 13, 0x00, 0x00, 0x00, 14, 0xF7]  // CMP equal R13 = (R0 == R14)
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    @Test func isValidOnOwnedSnapshotIsConstTrue() {
        let r = FirmataTaskRecorder()
        let resp = r.httpGet("http://x")
        r.json.snapshot(resp.body)            // owned -> always valid
        let v = resp.body.isValid()
        #expect(v.index == nil)           // a literal true, not a register read
    }

    // MARK: - board.json namespace (selects the handle's source, then inspects)

    @Test func jsonNamespaceSelectsLiveThenInspects() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")                 // borrowed; generation captured in R0
        let v = r.json.getNumber(h.body, "id", into: .reg(7), found: .reg(8))
        #expect(v.index == 7)
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x24, 0x00, 0x00, 0xF7] +              // SELECT live, gen R0
            [0xF0, 0x7B, 0x7F, 0x16, 7, 8, 0, 0x02, 0x00, 105, 100, 0xF7]  // JSON_NUM "id" -> R7
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    @Test func jsonNamespaceSnapshotSelectsSnapshot() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x")
        r.json.snapshot(h.body)                        // in-place -> owns slot 0
        #expect(h.body.snapshotSlot?.index == 0)
        _ = r.json.getNumber(h.body, "id", into: .reg(7), found: .reg(8))
        let tail: [UInt8] =
            [0xF0, 0x7B, 0x7F, 0x24, 0x01, 0x00, 0xF7] +             // SELECT snapshot (sel = 1)
            [0xF0, 0x7B, 0x7F, 0x16, 7, 8, 0, 0x02, 0x00, 105, 100, 0xF7]
        #expect(Array(r.bytes.suffix(tail.count)) == tail)
    }

    // MARK: - Inspection operands flow into ifTrue / auto-register descent

    @Test func jsonNumberFlowsIntoIfTrue() {
        let r = FirmataTaskRecorder()
        let h = r.httpGet("http://x", statusInto: .reg(0))
        let pct = r.json.getNumber(h.body, "changePercent", scaledBy: 2)   // dst=15, found=14
        #expect(pct.index == 15)
        r.ifTrue(pct, .greaterThan, .number(0)) { $0.digitalWrite(pin: .pin(2), high: true) }
        // The next auto-allocated read should be R13 (15 and 14 already taken).
        let nxt = r.json.bodyContains(h.body, "x")
        #expect(nxt.index == 13)
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
