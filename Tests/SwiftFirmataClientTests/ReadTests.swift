import Testing
@testable import SwiftFirmataClient

@Suite("LiveReads")
struct ReadTests {

    private func connected() async -> (FirmataClient, MockTransport) {
        let transport = MockTransport()
        let client = FirmataClient(transport: transport)
        await client.connect()
        await Task.yield()
        return (client, transport)
    }

    @Test func digitalReadReturnsPinBit() async throws {
        let (client, transport) = await connected()
        async let read = client.digitalRead(pin: .pin(2))
        await Task.yield()
        transport.injectDigital(port: 0, pinMask: 0b0000_0100)   // pin 2 HIGH
        let value = try await read
        #expect(value == true)
        // It enabled reporting for port 0 to force a fresh report.
        #expect(transport.sentBytes.contains([0xD0, 0x01]))
    }

    @Test func digitalReadLow() async throws {
        let (client, transport) = await connected()
        async let read = client.digitalRead(pin: .pin(5))
        await Task.yield()
        transport.injectDigital(port: 0, pinMask: 0b0000_0100)   // pin 5 is LOW here
        #expect(try await read == false)
    }

    @Test func analogReadReturnsValue() async throws {
        let (client, transport) = await connected()
        async let read = client.analogRead(channel: .channel(0))
        await Task.yield()
        transport.injectAnalog(channel: 0, value: 512)
        #expect(try await read == 512)
        #expect(transport.sentBytes.contains([0xC0, 0x01]))      // report analog ch0
    }

    @Test func digitalReadTimesOut() async {
        let (client, _) = await connected()
        await #expect(throws: FirmataError.self) {
            _ = try await client.digitalRead(pin: .pin(2), timeout: .milliseconds(40))
        }
    }
}
