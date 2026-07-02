# ``SwiftFirmataClient``

Drive a Firmata board from Swift — live control over Wi-Fi/BLE/TCP/USB serial,
plus recorded tasks the board runs on its own.

## Overview

``FirmataClient`` is an actor speaking Firmata 2.x over any ``FirmataTransport``.
Every call is `async`; board→host traffic arrives on ``FirmataClient/messages``.

```swift
let client = FirmataClient(transport: BonjourTransport())
await client.connect()

try await client.setPinMode(2, mode: .output)
try await client.digitalWrite(pin: 2, high: true)

// Runs on the board, forever, with nobody connected:
try await client.uploadTask(id: 1, repeatEvery: .milliseconds(500)) { board in
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(250))
    board.digitalWrite(pin: .pin(2), high: false)
}
```

Four transports ship with the package — ``BonjourTransport`` (mDNS discovery),
``TCPTransport`` (known host:port), ``BLETransport`` (Nordic UART Service), and
``SerialTransport`` (USB, macOS) — or conform to ``FirmataTransport`` yourself.

Inside ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)`` you record
onto a ``FirmataTaskRecorder``: the live verbs plus the on-device extension —
registers, branches, arithmetic, I²C reads, HTTP + JSON inspection, strings,
and nested tasks. The README's compatibility table maps client features to
required firmware versions; the repository COOKBOOK has a recipe per feature.

## Topics

### Connecting

- ``FirmataClient``
- ``FirmataTransport``
- ``BonjourTransport``
- ``TCPTransport``
- ``BLETransport``
- ``SerialTransport``
- ``FirmataDisconnectReason``
- ``FirmataError``

### Incoming traffic

- ``FirmataMessage``
- ``PinState``
- ``I2CReply``
- ``ProtocolVersion``
- ``FirmwareInfo``
- ``PinCapability``

### Live pin identities

- ``FirmataPin``
- ``FirmataChannel``
- ``PinMode``

### Internet & provisioning

- ``HTTPResponse``
- ``WiFiStatus``

### Tasks

- ``FirmataTaskRecorder``
- ``SchedulerTask``

### Recorder operands

- ``TaskOperand``
- ``TaskNumber``
- ``TaskFloat``
- ``TaskBool``
- ``TaskRegister``
- ``TaskLiteral``
- ``TaskNumberRegister``
- ``TaskFloatRegister``
- ``TaskBoolRegister``
- ``TaskNumberLiteral``
- ``TaskFloatLiteral``
- ``TaskBoolLiteral``
- ``TaskComparison``
- ``TaskPin``
- ``TaskChannel``

### Recorder internet, JSON & strings

- ``TaskHTTPResponse``
- ``TaskResponseBody``
- ``TaskJSONOps``
- ``TaskStringOps``
- ``TaskString``
- ``TaskJSONSlot``
- ``TaskStringSlot``
- ``TaskJSONType``
- ``TaskJSONValueType``
