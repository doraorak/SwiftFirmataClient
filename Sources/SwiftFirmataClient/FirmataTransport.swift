/**
 The byte pipe a ``FirmataClient`` speaks through. Two requirements: write bytes,
 and expose incoming bytes as one stream that ends (or throws) when the link dies.

 Four conformances ship with the package — ``BonjourTransport``, ``TCPTransport``,
 ``BLETransport``, ``SerialTransport`` — and they double as reference
 implementations for writing your own.
 */
public protocol FirmataTransport: Sendable {
    /// Write raw bytes to the device.
    func send(_ bytes: [UInt8]) async throws

    /// Produce an async stream of raw bytes received from the device.
    /// The stream ends (finishes or throws) when the connection closes.
    func openStream() -> AsyncThrowingStream<UInt8, Error>
}
