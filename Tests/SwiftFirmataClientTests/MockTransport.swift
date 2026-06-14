import Foundation
import SwiftFirmataClient

/// A loopback transport for testing.
///
/// - Bytes passed to ``send(_:)`` are captured in ``sentBytes``.
/// - Call ``inject(_:)`` to push bytes that the client will receive,
///   or use ``injectResponse(for:)`` to synthesise standard replies
///   without hand-crafting byte sequences.
final class MockTransport: FirmataTransport, @unchecked Sendable {

    // MARK: - Sent bytes

    private let lock = NSLock()
    private var _sentBytes: [[UInt8]] = []

    /// All byte arrays passed to ``send(_:)``, in order.
    var sentBytes: [[UInt8]] {
        lock.withLock { _sentBytes }
    }

    /// The last byte array written, for quick assertions.
    var lastSent: [UInt8]? { sentBytes.last }

    // MARK: - Inbound stream

    private var inboundContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    private let streamReady = ManagedCriticalState(false)

    func send(_ bytes: [UInt8]) async throws {
        lock.withLock { _sentBytes.append(bytes) }
    }

    func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            self.inboundContinuation = continuation
            self.streamReady.withCriticalRegion { $0 = true }
        }
    }

    // MARK: - Injection helpers

    /// Push raw bytes into the client's receive path.
    func inject(_ bytes: [UInt8]) {
        for b in bytes { inboundContinuation?.yield(b) }
    }

    /// Finish the inbound stream (simulates a closed connection).
    func close() { inboundContinuation?.finish() }

    /// Simulate the device throwing a transport error.
    func fail(with error: Error) { inboundContinuation?.finish(throwing: error) }

    // MARK: - Canned response builders

    /// Inject a protocol-version reply (0xF9, major, minor).
    func injectProtocolVersion(major: UInt8 = 2, minor: UInt8 = 8) {
        inject([0xF9, major, minor])
    }

    /// Inject a REPORT_FIRMWARE SysEx response.
    func injectFirmware(major: UInt8 = 1, minor: UInt8 = 0, name: String = "StandardFirmata") {
        var bytes: [UInt8] = [0xF0, 0x79, major, minor]
        for scalar in name.unicodeScalars {
            bytes.append(UInt8(scalar.value & 0x7F))
            bytes.append(UInt8((scalar.value >> 7) & 0x7F))
        }
        bytes.append(0xF7)
        inject(bytes)
    }

    /// Inject a CAPABILITY_RESPONSE SysEx.
    /// `pinModes` is a list-of-pins; each pin is a list of (mode, resolution) pairs.
    func injectCapability(pinModes: [[(PinMode, UInt8)]]) {
        var bytes: [UInt8] = [0xF0, 0x6C]
        for pin in pinModes {
            for (mode, res) in pin {
                bytes.append(mode.rawValue)
                bytes.append(res)
            }
            bytes.append(0x7F)
        }
        bytes.append(0xF7)
        inject(bytes)
    }

    /// Inject an ANALOG_MAPPING_RESPONSE SysEx.
    /// `channelByPin` index = digital pin, value = analog channel (0x7F = not analog).
    func injectAnalogMapping(_ channelByPin: [UInt8]) {
        inject([0xF0, 0x6A] + channelByPin + [0xF7])
    }

    /// Inject a PIN_STATE_RESPONSE SysEx.
    func injectPinState(pin: UInt8, mode: PinMode, value: Int32) {
        var bytes: [UInt8] = [0xF0, 0x6E, pin, mode.rawValue]
        var v = value
        repeat {
            bytes.append(UInt8(v & 0x7F))
            v >>= 7
        } while v != 0
        bytes.append(0xF7)
        inject(bytes)
    }

    /// Inject an analog message (0xE0+channel, LSB, MSB).
    func injectAnalog(channel: UInt8, value: UInt16) {
        inject([0xE0 | (channel & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)])
    }

    /// Inject a digital port message (0x90+port, pinMask LSB, pinMask MSB).
    func injectDigital(port: UInt8, pinMask: UInt8) {
        inject([0x90 | (port & 0x0F), pinMask & 0x7F, (pinMask >> 7) & 0x01])
    }

    /// Inject an I2C_REPLY SysEx.
    func injectI2CReply(address: UInt16, register: UInt16, data: [UInt8]) {
        var bytes: [UInt8] = [
            0xF0, 0x77,
            UInt8(address & 0x7F), UInt8((address >> 7) & 0x07),
            UInt8(register & 0x7F), UInt8((register >> 7) & 0x7F),
        ]
        for b in data {
            bytes.append(b & 0x7F)
            bytes.append((b >> 7) & 0x01)
        }
        bytes.append(0xF7)
        inject(bytes)
    }

    /// Inject a STRING_DATA SysEx.
    func injectString(_ text: String) {
        var bytes: [UInt8] = [0xF0, 0x71]
        for scalar in text.unicodeScalars {
            bytes.append(UInt8(scalar.value & 0x7F))
            bytes.append(UInt8((scalar.value >> 7) & 0x7F))
        }
        bytes.append(0xF7)
        inject(bytes)
    }
}

// MARK: - ManagedCriticalState (minimal backport)

final class ManagedCriticalState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(_ initial: State) { state = initial }
    @discardableResult
    func withCriticalRegion<R>(_ body: (inout State) -> R) -> R {
        lock.withLock { body(&state) }
    }
}
