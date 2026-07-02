import Foundation

// MARK: - Message enum

/// All messages that can arrive from a Firmata device.
public enum FirmataMessage: Sendable {
    /// 14-bit analog reading on the given channel (0-15).
    case analog(channel: UInt8, value: UInt16)

    /// 8-pin digital port state. `pinMask` bit N = state of port's pin N.
    case digital(port: UInt8, pinMask: UInt8)

    /// Protocol version report from the device.
    case protocolVersion(ProtocolVersion)

    /// Firmware name and version.
    case firmwareReport(FirmwareInfo)

    /// Supported modes per pin, indexed by pin number.
    case capabilityResponse(pins: [[PinCapability]])

    /// Analog channel number for each digital pin; 0x7F means not an analog pin.
    case analogMappingResponse(channelByPin: [UInt8])

    /// Current mode and output value / pull-up state for a pin.
    case pinStateResponse(PinState)

    /// UTF-8 string message from the device.
    case stringData(String)

    /// I2C read reply.
    case i2cReply(I2CReply)

    /// Extended analog value (pin > 15 or value > 14 bits).
    case extendedAnalog(pin: UInt8, value: Int32)

    /// Reply to a "query all scheduler tasks" request: the ids of stored tasks.
    case schedulerTaskList(taskIds: [UInt8])

    /// Reply to a "query scheduler task" request.
    case schedulerTask(SchedulerTask)

    /// Scheduler error (e.g. a query for a task id that does not exist).
    case schedulerError(taskId: UInt8)

    /**
     Result of an internet request made by the device (non-standard extension):
     the HTTP status code (`0` on error) and the response body. Delivered when a
     task's ``FirmataTaskRecorder/httpGet(_:statusInto:)`` runs while a host is
     connected, or in reply to a live ``FirmataClient/httpGet(_:timeout:)``.
     */
    case httpResponse(status: Int, body: String)

    /// Unrecognised SysEx message.
    case unknownSysEx(id: UInt8, data: [UInt8])
}

// MARK: - Associated value types

public struct ProtocolVersion: Sendable, CustomStringConvertible {
    public let major: UInt8
    public let minor: UInt8

    public var description: String { "\(major).\(minor)" }
}

public struct FirmwareInfo: Sendable, CustomStringConvertible {
    public let major: UInt8
    public let minor: UInt8
    public let name: String

    public var description: String { "\(name) v\(major).\(minor)" }
}

public struct PinCapability: Sendable {
    public let mode: PinMode
    /// Bit resolution for this mode (e.g. 10 for a 10-bit ADC, 1 for digital).
    public let resolution: UInt8
}

public struct PinState: Sendable {
    public let pin: UInt8
    public let mode: PinMode
    /// For output modes: the last written value.
    /// For digital input: 1 if pull-up is enabled, 0 otherwise.
    public let value: Int32
}

public struct I2CReply: Sendable {
    public let address: UInt16
    /**
     The peripheral's internal register **address** the reply was read from (the
     sub-address written before the read). This is an address *inside the I2C device*
     and is unrelated to the board's on-device logic registers (``TaskNumberRegister``).
     */
    public let registerAddress: UInt16
    public let data: [UInt8]
}

/**
 Result of an internet request the device made over its Wi-Fi
 (non-standard extension). Returned by ``FirmataClient/httpGet(_:timeout:)``
 and ``FirmataClient/httpPost(_:body:timeout:)``.
 Result of an encrypted Wi-Fi provisioning op (non-standard extension) —
 returned by ``FirmataClient/provisionWiFi(ssid:password:timeout:)`` and
 ``FirmataClient/queryWiFiStatus(timeout:)``.
 */
public struct WiFiStatus: Sendable {
    /// `true` if the device is currently joined to Wi-Fi.
    public let connected: Bool
    /// The device's IP address while connected, else `nil`.
    public let ip: String?
}

public struct HTTPResponse: Sendable {
    /// HTTP status code (`200`, `404`, …), or `0` if the device's Wi-Fi was down
    /// or the request failed.
    public let status: Int
    /// The response body (the device retains and returns up to ~4 KB).
    public let body: String

    /// `true` for a 2xx status.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

extension HTTPResponse {
    /// Parse the body as JSON into a foundation object graph
    /// (`[String: Any]` / `[Any]` / …). Throws if the body isn't valid JSON.
    public func json(options: JSONSerialization.ReadingOptions = []) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(body.utf8), options: options)
    }

    /**
     Decode the body into a `Decodable` type.
     ```swift
     struct Quote: Decodable { let symbol: String; let price: Double }
     let q = try (await board.httpGet(url)).decode(Quote.self)
     ```
     */
    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: Data(body.utf8))
    }
}
