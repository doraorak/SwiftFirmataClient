import Testing
import Foundation
@testable import SwiftFirmataClient

@Suite("DisconnectReason")
struct DisconnectReasonTests {

    private func connected() async -> (FirmataClient, MockTransport) {
        let transport = MockTransport()
        let client = FirmataClient(transport: transport)
        await client.connect()
        await Task.yield()
        return (client, transport)
    }

    @Test func localRequest() async {
        let (client, _) = await connected()
        await client.disconnect()
        #expect(await client.lastDisconnectReason == .localRequest)
    }

    @Test func transportClosed() async {
        let (client, transport) = await connected()
        let drain = Task { for await _ in client.messages {} }
        await Task.yield()
        transport.close()                 // device/network closed the link
        await drain.value
        #expect(await client.lastDisconnectReason == .transportClosed)
    }

    @Test func evictedByAnotherClient() async {
        let (client, transport) = await connected()
        let drain = Task { for await _ in client.messages {} }
        await Task.yield()
        // Firmware sends the standard eviction notice, then closes the link.
        transport.injectString(FirmataClient.evictionNotice)
        transport.close()
        await drain.value
        #expect(await client.lastDisconnectReason == .replacedByAnotherClient)
    }

    @Test func evictionSentinelIsNotSurfacedAsAMessage() async {
        let (client, transport) = await connected()
        let received = Captured()
        let drain = Task {
            for await msg in client.messages {
                if case .stringData(let s) = msg { received.append(s) }
            }
        }
        await Task.yield()
        transport.injectString("hello")                     // a normal device string
        transport.injectString(FirmataClient.evictionNotice) // the sentinel
        transport.close()
        await drain.value
        // The normal string is delivered; the sentinel is swallowed.
        #expect(received.values == ["hello"])
    }
}

/// Tiny lock-guarded sink so the streaming task can record without data races.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func append(_ s: String) { lock.withLock { _values.append(s) } }
    var values: [String] { lock.withLock { _values } }
}
