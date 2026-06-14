import Foundation
import Network

/// Discovers a Firmata device advertised via mDNS/Bonjour and connects over TCP.
///
/// On the ESP32 side (inside `setup()`, after WiFi connects):
/// ```cpp
/// #include <ESPmDNS.h>
/// MDNS.begin("esp32-firmata");
/// MDNS.addService("firmata", "tcp", 3030);
/// ```
///
/// Usage:
/// ```swift
/// let transport = BonjourTransport()          // finds first "_firmata._tcp" service
/// let transport = BonjourTransport(named: "esp32-livingroom")  // filter by instance name
/// ```
public final class BonjourTransport: FirmataTransport, @unchecked Sendable {

    private let serviceType: String
    private let instanceName: String?
    private var browser: NWBrowser?
    private var connection: NWConnection?

    /// Connection-readiness gate. `send` must not run before the TCP connection
    /// reaches `.ready`; otherwise it would throw `transportClosed` while the
    /// browser is still discovering the device. Guarded by `lock`.
    private let lock = NSLock()
    private var isReady = false
    private var readyError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// How long to wait for discovery + connection before giving up.
    private let connectTimeout: TimeInterval

    public init(serviceType: String = "_firmata._tcp",
                named instanceName: String? = nil,
                connectTimeout: TimeInterval = 15) {
        self.serviceType    = serviceType
        self.instanceName   = instanceName
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
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: self.serviceType, domain: nil),
                using: .tcp
            )
            self.browser = browser

            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    self.markFailed(error)
                    continuation.finish(throwing: error)
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                let match = results.first {
                    guard let name = self.instanceName else { return true }
                    if case .service(let n, _, _, _) = $0.endpoint { return n == name }
                    return false
                }
                guard let match else { return }
                browser.cancel()

                // Prefer a direct IP:port endpoint extracted from the TXT record.
                // This bypasses mDNS A-record resolution for "esp32-firmata.local",
                // which can time out on home networks that don't relay multicast DNS.
                // txt[key] returns Substring? on Network.framework; String() converts it.
                let endpoint: NWEndpoint = {
                    guard case .bonjour(let txt) = match.metadata,
                          let ipRaw = txt["ip"]
                    else { return match.endpoint }

                    let ipStr = String(ipRaw)
                    guard !ipStr.isEmpty else { return match.endpoint }

                    var portNum: UInt16 = 3030
                    if let portRaw = txt["port"], let p = UInt16(String(portRaw)) {
                        portNum = p
                    }
                    return NWEndpoint.hostPort(host: NWEndpoint.Host(ipStr),
                                              port: NWEndpoint.Port(rawValue: portNum)!)
                }()

                self.openConnection(to: endpoint, continuation: continuation)
            }

            browser.start(queue: .global(qos: .utility))

            // Overall discovery + connect timeout, so a missing device (or denied
            // Local Network permission) surfaces as an error instead of hanging.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.connectTimeout) {
                if !self.isReadyOrFailed() {
                    let err = BonjourTransportError.timedOut
                    self.markFailed(err)
                    continuation.finish(throwing: err)
                }
            }

            continuation.onTermination = { _ in
                browser.cancel()
                self.connection?.cancel()
            }
        }
    }

    // MARK: - Private

    private func openConnection(
        to endpoint: NWEndpoint,
        continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    ) {
        let conn = NWConnection(to: endpoint, using: .tcp)
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
        receiveLoop(conn, continuation)
    }

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

public enum BonjourTransportError: Error {
    case timedOut
}
