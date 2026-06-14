/// Abstraction over the physical connection (serial port, TCP, BLE, etc.).
///
/// Implement this protocol to connect ``FirmataClient`` to your transport layer.
///
/// Example (TCP):
/// ```swift
/// final class TCPTransport: FirmataTransport {
///     private let connection: NWConnection
///
///     func send(_ bytes: [UInt8]) async throws { ... }
///
///     func openStream() -> AsyncThrowingStream<UInt8, Error> {
///         AsyncThrowingStream { continuation in
///             // read bytes from connection and yield them
///         }
///     }
/// }
/// ```
public protocol FirmataTransport: Sendable {
    /// Write raw bytes to the device.
    func send(_ bytes: [UInt8]) async throws

    /// Produce an async stream of raw bytes received from the device.
    /// The stream ends (finishes or throws) when the connection closes.
    func openStream() -> AsyncThrowingStream<UInt8, Error>
}
