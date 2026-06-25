/// Firmata protocol v2.8.0 client library for Arduino / ESP32.
///
/// Typical usage:
/// ```swift
/// let transport = MySerialTransport(port: "/dev/tty.usbmodem1")
/// let client = FirmataClient(transport: transport)
/// await client.connect()
///
/// try await client.setPinMode(13, mode: .output)
/// try await client.digitalWrite(pin: 13, high: true)
///
/// let fw = try await client.queryFirmware()
/// print("\(fw.name) v\(fw.major).\(fw.minor)")
/// ```

public enum FirmataError: Error, Sendable {
    case transportClosed
    case invalidData
    case noResponse
    /// Wi-Fi provisioning: the device rejected the credentials (the encrypted
    /// handshake failed to authenticate — wrong key / tampered / corrupted frame).
    case wifiCredentialsRejected
}
