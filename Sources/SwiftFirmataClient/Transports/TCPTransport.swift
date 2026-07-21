import Foundation
import Network

/**
 Connects to a Firmata device at a known **host and port** over TCP — no mDNS
 discovery involved.

 Use this instead of ``BonjourTransport`` whenever the board's address is
 already known or Bonjour can't reach it: a static IP or DHCP reservation,
 another subnet, a VPN/Tailscale network, or an SSH/port-forward tunnel.
 (Bonjour multicast doesn't cross any of those.)

 Usage:
 ```swift
 let transport = TCPTransport(host: "192.168.1.87")          // firmware default port 3030
 let transport = TCPTransport(host: "firmata-wifi-esp32.local")   // direct mDNS-name resolution
 let transport = TCPTransport(host: "127.0.0.1", port: 4030) // through an SSH tunnel
 ```
 */
public final class TCPTransport: FirmataTransport, @unchecked Sendable {

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?

    /**
     Connection-readiness gate. `send` must not run before the TCP connection
     reaches `.ready`; otherwise it would throw `transportClosed` while the
     connection is still being established. Guarded by `lock`.
     */
    private let lock = NSLock()
    private var isReady = false
    private var readyError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// How long to wait for the connection before giving up.
    private let connectTimeout: TimeInterval

    /**
     - Parameters:
       - host: IP address or hostname (a `.local` mDNS name works too).
       - port: TCP port; the firmwares listen on `3030`.
       - connectTimeout: Seconds before an unreachable host surfaces as an error.
     */
    public init(host: String, port: UInt16 = 3030, connectTimeout: TimeInterval = 15) {
        self.host           = NWEndpoint.Host(host)
        self.port           = NWEndpoint.Port(rawValue: port) ?? 3030
        self.connectTimeout = connectTimeout
    }

    // MARK: - FirmataTransport

    public func send(_ bytes: [UInt8]) async throws {
        try await waitUntilReady()
        guard let connection else { throw FirmataError.transportClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume() }
            })
        }
    }

    public func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            let conn = NWConnection(host: self.host, port: self.port, using: .tcp)
            self.connection = conn

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:             self.markReady()
                case .failed(let error): self.markFailed(error); continuation.finish(throwing: error)
                case .cancelled:         continuation.finish()
                default: break
                }
            }

            conn.start(queue: .global(qos: .utility))
            self.receiveLoop(conn, continuation)

            // Surface an unreachable/blocked host as an error instead of hanging
            // (NWConnection retries silently in `.waiting` otherwise).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.connectTimeout) {
                if !self.isReadyOrFailed() {
                    let err = TCPTransportError.timedOut
                    self.markFailed(err)
                    conn.cancel()
                    continuation.finish(throwing: err)
                }
            }

            continuation.onTermination = { _ in
                conn.cancel()
            }
        }
    }

    // MARK: - Private

    private func receiveLoop(
        _ conn: NWConnection,
        _ continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, isComplete, error in
            if let error  { continuation.finish(throwing: error); return }
            data?.forEach { continuation.yield($0) }
            if isComplete { continuation.finish(); return }
            self.receiveLoop(conn, continuation)
        }
    }

    // MARK: - Readiness gate

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isReady              { lock.unlock(); cont.resume(); return }
            if let e = readyError   { lock.unlock(); cont.resume(throwing: e); return }
            readyWaiters.append(cont)
            lock.unlock()
        }
    }

    private func markReady() {
        lock.lock()
        if isReady || readyError != nil { lock.unlock(); return }
        isReady = true
        let waiters = readyWaiters; readyWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func markFailed(_ error: Error) {
        lock.lock()
        if isReady || readyError != nil { lock.unlock(); return }
        readyError = error
        let waiters = readyWaiters; readyWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func isReadyOrFailed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isReady || readyError != nil
    }
}

// MARK: - Errors

public enum TCPTransportError: Error {
    case timedOut
}
