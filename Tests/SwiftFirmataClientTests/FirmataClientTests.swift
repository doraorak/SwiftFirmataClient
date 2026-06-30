import Testing
@testable import SwiftFirmataClient

// MARK: - FirmataClient integration tests

@Suite("FirmataClient")
struct FirmataClientTests {

    // MARK: - Helpers

    /// Builds a connected client backed by a MockTransport.
    /// The mock's stream is open; the caller injects bytes as needed.
    private func makeClient() async -> (FirmataClient, MockTransport) {
        let transport = MockTransport()
        let client = FirmataClient(transport: transport)
        await client.connect()
        // Yield so the read loop task is running before we inject bytes.
        await Task.yield()
        return (client, transport)
    }

    // MARK: - Digital I/O

    @Test func setOutputMode() async throws {
        let (client, transport) = await makeClient()
        try await client.setPinMode(13, mode: .output)
        #expect(transport.lastSent == [0xF4, 13, 0x01])
    }

    @Test func setPullupMode() async throws {
        let (client, transport) = await makeClient()
        try await client.setPinMode(2, mode: .inputPullup)
        #expect(transport.lastSent == [0xF4, 2, 0x0B])
    }

    @Test func digitalWriteHigh() async throws {
        let (client, transport) = await makeClient()
        try await client.digitalWrite(pin: 13, high: true)
        #expect(transport.lastSent == [0xF5, 13, 0x01])
    }

    @Test func digitalWriteLow() async throws {
        let (client, transport) = await makeClient()
        try await client.digitalWrite(pin: 13, high: false)
        #expect(transport.lastSent == [0xF5, 13, 0x00])
    }

    @Test func writeDigitalPort() async throws {
        let (client, transport) = await makeClient()
        // pinMask = 0xFF: bits 0-6 in first byte, bit 7 in second
        try await client.writeDigitalPort(0, pinMask: 0xFF)
        #expect(transport.lastSent == [0x90, 0x7F, 0x01])
    }

    @Test func reportDigitalPort() async throws {
        let (client, transport) = await makeClient()
        try await client.reportDigitalPort(1, enable: true)
        #expect(transport.lastSent == [0xD1, 0x01])
    }

    // MARK: - Analog I/O

    @Test func analogWriteStandard() async throws {
        let (client, transport) = await makeClient()
        // pin 3, value 512 = 0x200 => LSB=0x00, MSB=0x04
        try await client.analogWrite(channel: 3, value: 512)
        #expect(transport.lastSent == [0xE3, 0x00, 0x04])
    }

    @Test func analogWriteHighPin() async throws {
        let (client, transport) = await makeClient()
        // Pin 16 must use extended analog SysEx
        try await client.analogWrite(channel: 16, value: 100)
        let sent = transport.lastSent ?? []
        #expect(sent.first == 0xF0)
        #expect(sent[1] == 0x6F)           // EXTENDED_ANALOG
        #expect(sent[2] == 16)             // pin
        #expect(sent.last == 0xF7)
    }

    @Test func extendedAnalogWrite1000() async throws {
        let (client, transport) = await makeClient()
        // 1000 = 0x3E8 = 0b11_1110_1000
        // 7-bit chunks: bits[0-6]=0x68, bits[7-9]=0x07
        try await client.extendedAnalogWrite(pin: 9, value: 1000)
        #expect(transport.lastSent == [0xF0, 0x6F, 9, 0x68, 0x07, 0xF7])
    }

    @Test func reportAnalogChannel() async throws {
        let (client, transport) = await makeClient()
        try await client.reportAnalogChannel(0, enable: true)
        #expect(transport.lastSent == [0xC0, 0x01])
    }

    // MARK: - System

    @Test func systemReset() async throws {
        let (client, transport) = await makeClient()
        try await client.systemReset()
        #expect(transport.lastSent == [0xFF])
    }

    @Test func setSamplingInterval() async throws {
        let (client, transport) = await makeClient()
        // 500 ms => LSB = 500 & 0x7F = 0x74, MSB = 500 >> 7 = 0x03
        try await client.setSamplingInterval(.milliseconds(500))
        #expect(transport.lastSent == [0xF0, 0x7A, 0x74, 0x03, 0xF7])
    }

    @Test func sendString() async throws {
        let (client, transport) = await makeClient()
        // "A" = 65 => LSB=65, MSB=0
        try await client.sendString("A")
        #expect(transport.lastSent == [0xF0, 0x71, 65, 0, 0xF7])
    }

    // MARK: - Queries

    @Test func queryProtocolVersion() async throws {
        let (client, transport) = await makeClient()
        async let version = client.queryProtocolVersion()
        await Task.yield()
        transport.injectProtocolVersion(major: 2, minor: 8)
        let v = try await version
        #expect(v.major == 2 && v.minor == 8)
        #expect(transport.lastSent == [0xF9])
    }

    @Test func queryFirmware() async throws {
        let (client, transport) = await makeClient()
        async let firmware = client.queryFirmware()
        await Task.yield()
        transport.injectFirmware(major: 2, minor: 3, name: "StandardFirmata")
        let fw = try await firmware
        #expect(fw.name == "StandardFirmata")
        #expect(fw.major == 2 && fw.minor == 3)
        #expect(transport.lastSent == [0xF0, 0x79, 0xF7])
    }

    @Test func queryCapabilities() async throws {
        let (client, transport) = await makeClient()
        async let caps = client.queryCapabilities()
        await Task.yield()
        transport.injectCapability(pinModes: [
            [(.input, 1), (.output, 1)],
            [(.analog, 10), (.pwm, 8)],
        ])
        let pins = try await caps
        #expect(pins.count == 2)
        #expect(pins[1].contains { $0.mode == .pwm })
    }

    @Test func queryAnalogMapping() async throws {
        let (client, transport) = await makeClient()
        async let mapping = client.queryAnalogMapping()
        await Task.yield()
        transport.injectAnalogMapping([0x7F, 0x7F, 0x00, 0x01, 0x02])
        let map = try await mapping
        #expect(map == [0x7F, 0x7F, 0x00, 0x01, 0x02])
    }

    @Test func queryPinState() async throws {
        let (client, transport) = await makeClient()
        async let state = client.queryPinState(pin: 13)
        await Task.yield()
        transport.injectPinState(pin: 13, mode: .output, value: 1)
        let s = try await state
        #expect(s.pin == 13)
        #expect(s.mode == .output)
        #expect(s.value == 1)
        #expect(transport.lastSent == [0xF0, 0x6D, 13, 0xF7])
    }

    // MARK: - I2C

    @Test func i2cConfigSent() async throws {
        let (client, transport) = await makeClient()
        try await client.configureI2C(delay: .microseconds(100))
        // 100 => LSB = 100, MSB = 0
        #expect(transport.lastSent == [0xF0, 0x78, 100, 0, 0xF7])
    }

    @Test func i2cWrite() async throws {
        let (client, transport) = await makeClient()
        // Address 0x3C (7-bit), write bytes [0x00, 0xAE]
        try await client.i2cWrite(address: 0x3C, data: [0x00, 0xAE])
        let sent = transport.lastSent ?? []
        #expect(sent[0] == 0xF0)
        #expect(sent[1] == 0x76)            // I2C_REQUEST
        #expect(sent[2] == 0x3C)            // address LSB
        // control byte: mode=write(00), bit5=0(7-bit), no restart => 0x00
        #expect(sent[3] == 0x00)
        // 0x00 encoded: 0x00, 0x00
        #expect(sent[4] == 0x00 && sent[5] == 0x00)
        // 0xAE = 0b10101110 => LSB=0x2E, MSB=0x01
        #expect(sent[6] == 0x2E && sent[7] == 0x01)
        #expect(sent.last == 0xF7)
    }

    @Test func i2cReadOnce() async throws {
        let (client, transport) = await makeClient()
        async let reply = client.i2cReadOnce(address: 0x48, count: 2)
        await Task.yield()
        transport.injectI2CReply(address: 0x48, registerAddress: 0, data: [0x12, 0x34])
        let r = try await reply
        #expect(r.address == 0x48)
        #expect(r.data == [0x12, 0x34])

        // Verify the sent request has mode=readOnce(01) in bits[4:3] of control byte
        let sent = transport.sentBytes.last ?? []
        let control = sent[3]
        #expect((control >> 3) & 0x03 == 0x01)  // readOnce
    }

    // MARK: - Messages stream

    @Test func analogMessageDeliveredToStream() async throws {
        let (client, transport) = await makeClient()
        let task = Task { () -> FirmataMessage? in
            for await msg in client.messages { return msg }
            return nil
        }
        await Task.yield()
        transport.injectAnalog(channel: 0, value: 512)
        let received = await task.value
        guard case .analog(let ch, let val) = received else {
            Issue.record("Expected .analog in stream"); return
        }
        #expect(ch == 0 && val == 512)
    }

    @Test func digitalMessageDeliveredToStream() async throws {
        let (client, transport) = await makeClient()
        let task = Task { () -> FirmataMessage? in
            for await msg in client.messages { return msg }
            return nil
        }
        await Task.yield()
        transport.injectDigital(port: 2, pinMask: 0b00001111)
        let received = await task.value
        guard case .digital(let port, let mask) = received else {
            Issue.record("Expected .digital in stream"); return
        }
        #expect(port == 2 && mask == 0b00001111)
    }

    @Test func stringMessageDeliveredToStream() async throws {
        let (client, transport) = await makeClient()
        let task = Task { () -> FirmataMessage? in
            for await msg in client.messages { return msg }
            return nil
        }
        await Task.yield()
        transport.injectString("hello")
        let received = await task.value
        guard case .stringData(let s) = received else {
            Issue.record("Expected .stringData in stream"); return
        }
        #expect(s == "hello")
    }

    // MARK: - Disconnect

    @Test func disconnectCancelsStream() async throws {
        let (client, transport) = await makeClient()
        let task = Task { () -> Bool in
            for await _ in client.messages {}
            return true
        }
        await Task.yield()
        await client.disconnect()
        let streamEnded = await task.value
        #expect(streamEnded)
        _ = transport  // suppress unused warning
    }
}
