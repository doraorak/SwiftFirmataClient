#if os(macOS)
import Foundation

/// Talks Firmata over a USB serial port (macOS) — the board's UART0, the same
/// port used for flashing and the boot log console.
///
/// Firmware behaviour (both ESP32 firmwares, 2.7.0+): the port boots as the log
/// console; the **first byte** the host sends claims the Firmata session — the
/// console goes quiet and the port speaks Firmata until another transport takes
/// over or the board reboots.
///
/// Two quirks of USB-serial on ESP32 dev boards, both handled here:
/// - **Opening the port auto-resets the board** (DTR/RTS wiring). `openStream`
///   therefore delivers everything the board prints while booting — ASCII log
///   noise the Firmata parser ignores by design. Wait for the boot to settle
///   (`FirmataClient.connect()` + your first query round-trip does this
///   naturally), or pass `settleDelay` to drop bytes received in that window.
/// - There is **no disconnect event**; closing the app just leaves the board
///   running (tasks keep going, like Wi-Fi).
///
/// Usage:
/// ```swift
/// let transport = SerialTransport(path: "/dev/cu.wchusbserial110")
/// let client = FirmataClient(transport: transport)
/// await client.connect()
/// ```
public final class SerialTransport: FirmataTransport, @unchecked Sendable {

    private let path: String
    private let baudRate: speed_t
    private let settleDelay: TimeInterval
    private let lock = NSLock()
    private var fd: Int32 = -1

    /// - Parameters:
    ///   - path: The device node, e.g. `/dev/cu.usbserial-0001` or
    ///     `/dev/cu.wchusbserial110` (`ls /dev/cu.*`). Use the `cu.` node, not `tty.`.
    ///   - baudRate: Line speed; both ESP32 firmwares use 115200.
    ///   - settleDelay: Bytes received this long after opening are discarded —
    ///     the board's boot chatter after the open-triggered auto-reset. `0`
    ///     forwards everything (the Firmata parser skips ASCII noise anyway).
    public init(path: String, baudRate: speed_t = 115200, settleDelay: TimeInterval = 0) {
        self.path = path
        self.baudRate = baudRate
        self.settleDelay = settleDelay
    }

    // MARK: - FirmataTransport

    public func send(_ bytes: [UInt8]) async throws {
        let fd = try openIfNeeded()
        var buf = bytes
        var off = 0
        while off < buf.count {
            let n = buf.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: off), buf.count - off)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { try await Task.sleep(for: .milliseconds(1)); continue }
                throw FirmataError.transportClosed
            }
            off += n
        }
    }

    public func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            let fd: Int32
            do { fd = try openIfNeeded() } catch {
                continuation.finish(throwing: error)
                return
            }
            let openedAt = Date()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler { [settleDelay] in
                var chunk = [UInt8](repeating: 0, count: 1024)
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    if settleDelay > 0, Date().timeIntervalSince(openedAt) < settleDelay { return }
                    for i in 0..<n { continuation.yield(chunk[i]) }
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    continuation.finish(throwing: FirmataError.transportClosed)
                    source.cancel()
                }
            }
            source.setCancelHandler { [weak self] in self?.closePort() }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }

    // MARK: - POSIX plumbing

    private func openIfNeeded() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return fd }

        // O_NONBLOCK so open() doesn't hang waiting for a carrier; switched back
        // to blocking below (reads are readiness-driven via DispatchSource).
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw FirmataError.transportClosed }

        var tio = termios()
        guard tcgetattr(f, &tio) == 0 else { close(f); throw FirmataError.transportClosed }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)     // no modem control; enable RX
        tio.c_cflag &= ~tcflag_t(HUPCL)             // don't drop DTR on close (avoids a reset on exit)
        cfsetspeed(&tio, baudRate)
        guard tcsetattr(f, TCSANOW, &tio) == 0 else { close(f); throw FirmataError.transportClosed }
        _ = fcntl(f, F_SETFL, 0)                    // back to blocking I/O
        tcflush(f, TCIOFLUSH)                       // drop whatever was buffered pre-open

        fd = f
        return f
    }

    private func closePort() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }
}
#endif
