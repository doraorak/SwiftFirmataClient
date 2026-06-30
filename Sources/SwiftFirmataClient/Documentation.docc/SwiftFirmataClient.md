# ``SwiftFirmataClient``

A concurrency-safe Firmata client for Swift — drive an Arduino, ESP32, or any
Firmata-compatible board from macOS or iOS over **Bonjour/TCP** or **BLE**.

## Overview

`SwiftFirmataClient` speaks **Firmata protocol v2.x** (the same command set as
StandardFirmata / ConfigurableFirmata) using Swift's structured concurrency.
The client is an `actor`, every operation is `async`, and incoming device
messages arrive as an `AsyncStream`.

```swift
import SwiftFirmataClient

let client = FirmataClient(transport: BonjourTransport())
await client.connect()

let fw = try await client.queryFirmware()
print("Connected to \(fw.name) v\(fw.major).\(fw.minor)")

try await client.setPinMode(2, mode: .output)
try await client.digitalWrite(pin: 2, high: true)   // LED on
```

### Connecting

A ``FirmataClient`` is built from a ``FirmataTransport``. Two transports ship
with the package, and you can provide your own (serial, socket, mock, …).

- term Bonjour / Wi-Fi: ``BonjourTransport`` discovers a `_firmata._tcp`
  service via mDNS and connects over TCP. It prefers a direct `ip`/`port` from
  the service's TXT record to sidestep flaky `.local` resolution.
- term BLE: ``BLETransport`` connects over the Nordic UART Service (NUS), the
  de-facto standard for Firmata-over-BLE.

```swift
let bonjour = FirmataClient(transport: BonjourTransport())
let ble     = FirmataClient(transport: BLETransport(peripheralName: "Firmata-ESP32"))
```

Add the matching usage-description keys to your **Info.plist**
(`NSLocalNetworkUsageDescription` + `NSBonjourServices` for Bonjour,
`NSBluetoothAlwaysUsageDescription` for BLE).

### Reading inputs

Every message the device sends is published on ``FirmataClient/messages``:

```swift
try await client.setPinMode(34, mode: .analog)
try await client.reportAnalogChannel(0, enable: true)

Task {
    for await message in client.messages {
        if case .analog(let channel, let value) = message {
            print("A\(channel) = \(value)")
        }
    }
}
```

For a single value instead of a stream, use the one-shot reads — they enable
reporting, await the next sample, and restore the prior state:

```swift
try await client.setPinMode(7, mode: .inputPullup)
let isHigh = try await client.digitalRead(pin: 7)         // Bool

try await client.setPinMode(34, mode: .analog)
let raw    = try await client.analogRead(channel: 0)      // UInt16
```

### Autonomous tasks (Firmata Scheduler)

The standard **Firmata Scheduler** extension lets you upload a timed sequence of
commands that the board runs on its own — it keeps running after you disconnect.
Use ``FirmataClient/uploadTask(id:startDelay:repeatEvery:_:)`` with a
``FirmataTaskRecorder``:

```swift
// Blink pin 2 forever, 400 ms on / 400 ms off — survives disconnect.
try await client.uploadTask(id: 2, repeatEvery: .milliseconds(400)) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(400))
    board.digitalWrite(pin: .pin(2), high: false)
}
// ...later:
try await client.deleteTask(id: 2)
```

> Tip: `{ board in … }` is a closure whose parameter `board` **is** the
> ``FirmataTaskRecorder``. You call `board.setPinMode(…)`, `board.digitalWrite(…)`,
> `board.delay(…)` on it to record steps — nothing is sent until `uploadTask` ships
> the whole recording. The name `board` is just a convention.

### On-device logic (scheduler extension)

> Important: An extension carried under the scheduler's reserved
> `EXTENDED_SCHEDULER_COMMAND` (`0x7F`). The Scheduler control protocol is
> unchanged, and a standard Firmata scheduler ignores these ops gracefully (no
> crash; the conditionals become no-ops). Acted on only by this project's ESP32
> firmware (`nonstandard-scheduler-logic` branch). See `NONSTANDARD.md`.

A task can also make its own decisions, so it doesn't just replay a fixed
sequence. The device has **16 global Int32 registers**; you load values into them
(a constant via ``FirmataTaskRecorder/setRegister(_:to:)``, or a reading via
``FirmataTaskRecorder/digitalRead(into:pin:)`` /
``FirmataTaskRecorder/analogRead(into:channel:)``) and branch on them with
``FirmataTaskRecorder/ifTrue(_:_:_:then:elseDo:)``:

```swift
// A night-light running entirely on the board, with nobody connected.
try await client.uploadTask(id: 3, repeatEvery: .milliseconds(1000)) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.analogRead(into: .reg(0), channel: .channel(0))                 // R0 = analog A0
    board.ifTrue(.reg(0), .lessThan, .number(300),        // dark?
        then:   { $0.digitalWrite(pin: 2, high: true) },   // LED on
        elseDo: { $0.digitalWrite(pin: 2, high: false) })  // else off
}
```

Operands are `.reg(0...15)` or `.number(value)`; comparisons are `==`, `!=`, `<`,
`>`, `<=`, `>=`. Branches are forward-only (no jumps/loops), so a task can decide
but can never hang the board; looping stays via `repeatEvery`.

### One client, one connection

A `FirmataClient` owns a single transport and connection for its lifetime. To
switch transports or reconnect, ``FirmataClient/disconnect()`` and create a new
one — never point two live clients at one board.

A Firmata board has a single master. A dual-transport firmware enforces this with
**latest-wins** arbitration: a new connection evicts the current one. When that
happens to you, ``FirmataClient/messages`` finishes and
``FirmataClient/lastDisconnectReason`` is
``FirmataDisconnectReason/replacedByAnotherClient`` (detected from the firmware's
standard eviction notice). Otherwise it is
``FirmataDisconnectReason/localRequest`` or
``FirmataDisconnectReason/transportClosed``.

```swift
Task {
    for await _ in client.messages {}        // drains until the link ends
    switch await client.lastDisconnectReason {
    case .replacedByAnotherClient: print("Another client took the board")
    case .transportClosed:         print("Connection dropped")
    default:                       break
    }
}
```

## Topics

### Essentials

- ``FirmataClient``
- ``FirmataTransport``
- ``FirmataError``
- ``FirmataDisconnectReason``

### Transports

- ``BonjourTransport``
- ``BonjourTransportError``
- ``BLETransport``
- ``BLETransportError``

### Pin model

- ``PinMode``
- ``PinCapability``
- ``PinState``

### Device messages

- ``FirmataMessage``
- ``ProtocolVersion``
- ``FirmwareInfo``
- ``FirmataParser``

### I2C

- ``I2CMode``
- ``I2CReply``

### Scheduler (autonomous tasks)

- ``FirmataTaskRecorder``
- ``SchedulerTask``

### On-device logic (non-standard extension)

- ``TaskOperand``
- ``TaskComparison``
