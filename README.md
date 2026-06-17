# SwiftFirmataClient

> **`no-extension` branch:** standard Firmata client only. For the on-device
> scheduler logic extension (registers + `if`/`else`), use the `main` branch.


A modern, concurrency-safe [Firmata](https://github.com/firmata/protocol) client for Swift — talk to an Arduino, ESP32, or any Firmata-compatible board from macOS or iOS over **Bonjour/TCP** or **BLE**.

Built on Swift’s structured concurrency: the client is an `actor`, every public API is `async`, and incoming messages are delivered as an `AsyncStream`.

```swift
let client = FirmataClient(transport: BonjourTransport())
await client.connect()

let fw = try await client.queryFirmware()
print("Connected to \(fw.name) v\(fw.major).\(fw.minor)")

try await client.setPinMode(2, mode: .output)
try await client.digitalWrite(pin: 2, value: true)   // LED on
```

## Features

- **Firmata protocol v2.x** — protocol/firmware/capability/analog-mapping/pin-state queries, digital & analog I/O, extended analog, PWM, sampling interval, strings, and full I2C.
- **Two built-in transports**
  - `BonjourTransport` — discovers `_firmata._tcp` services via mDNS and connects over TCP.
  - `BLETransport` — connects over the Nordic UART Service (NUS), the de-facto standard for Firmata-over-BLE.
- **Bring your own transport** — conform to the small `FirmataTransport` protocol to run Firmata over serial, a socket, a mock, or anything else.
- **Swift 6 / strict concurrency** — `Sendable` throughout, no data races, `async`/`await` end to end.
- **Tested** — a byte-level parser test suite plus integration tests over a mock transport.

## Requirements

| | |
|---|---|
| Platforms | macOS 13+, iOS 16+ |
| Toolchain | Swift 6.0+ (Xcode 16+) |
| Transports | `BonjourTransport`/`BLETransport` need `Network` / `CoreBluetooth` (Apple platforms) |

## Installation

### Swift Package Manager (Xcode)

File ▸ Add Package Dependencies… and enter:

```
https://github.com/doraorak/SwiftFirmataClient.git
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftFirmataClient", package: "SwiftFirmataClient"),
        ]
    ),
]
```

## Usage

### Connecting over Bonjour (Wi-Fi)

The board advertises `_firmata._tcp` on the local network; the client finds and connects to it automatically.

```swift
import SwiftFirmataClient

let client = FirmataClient(transport: BonjourTransport())          // first device found
// let client = FirmataClient(transport: BonjourTransport(named: "esp32-livingroom"))

await client.connect()
let caps = try await client.queryCapabilities()                    // [[PinCapability]] indexed by pin
```

On macOS/iOS, add to your **Info.plist**:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Discover and control Firmata devices on your network.</string>
<key>NSBonjourServices</key>
<array><string>_firmata._tcp</string></array>
```

### Connecting over BLE

```swift
let client = FirmataClient(transport: BLETransport())              // first NUS device
// let client = FirmataClient(transport: BLETransport(peripheralName: "Firmata-ESP32"))
await client.connect()
```

Add `NSBluetoothAlwaysUsageDescription` to your Info.plist.

### Reading inputs

Every message from the device is published on the `messages` stream:

```swift
try await client.setPinMode(34, mode: .analog)
try await client.reportAnalogPin(0, enable: true)                 // analog channel A0

Task {
    for await message in client.messages {
        switch message {
        case .analog(let channel, let value):  print("A\(channel) = \(value)")
        case .digital(let port, let mask):      print("port \(port) = \(mask, radix: 2)")
        default: break
        }
    }
}
```

### I2C

```swift
try await client.configureI2C()
try await client.i2cWrite(address: 0x3C, data: [0x00, 0xAE])      // e.g. SSD1306 display-off
let reply = try await client.i2cReadOnce(address: 0x48, register: 0x00, count: 2)
print(reply.data)
```

### Scheduling tasks (run after disconnect)

The device can store *tasks* — recorded sequences of Firmata messages with
delays — and run them on its own, even after the client disconnects (Firmata
Scheduler, SysEx `0x7B`). Build a task with the recorder, upload it, and leave:

```swift
// Blink pin 2 every 250 ms — forever, with no client connected.
try await client.uploadTask(id: 1, repeatEveryMs: 250) { t in
    t.setPinMode(2, mode: .output)
    t.digitalWrite(pin: 2, value: true)
    t.delay(ms: 250)
    t.digitalWrite(pin: 2, value: false)
}
await client.disconnect()          // the board keeps blinking
```

- `startDelayMs` delays the first run; `repeatEveryMs` makes the task loop with
  that gap (omit it for a one-shot, which runs once and is then removed).
- `uploadTask` confirms receipt with a round-trip before returning, so it is
  safe to `disconnect()` immediately afterwards.
- Tasks live in RAM — a power cycle or `systemReset()` clears them.
- Low-level control is also available: `createTask`, `addToTask`,
  `scheduleTask`, `deleteTask`, `resetTasks`, `queryAllTasks`, `queryTask`.

### Disconnecting

```swift
await client.disconnect()
```

### One client, one board

A `FirmataClient` owns a single transport/connection for its lifetime — to
switch transports (Bonjour ↔ BLE) or reconnect, `disconnect()` and make a new
one. A board has a single master; a dual-transport firmware enforces this with
**latest-wins** (a new connection on either transport evicts the current one).
When you are evicted, `messages` finishes and `lastDisconnectReason` tells you
why:

```swift
for await _ in client.messages {}            // drains until the link ends
switch await client.lastDisconnectReason {
case .replacedByAnotherClient: …             // another app/computer took over
case .transportClosed:         …             // network drop / device reset
case .localRequest, .none:     break         // you called disconnect()
}
```

This is fully standard-compliant: eviction is signalled with an ordinary
`STRING_DATA` sentinel, so nothing non-standard goes on the wire.

## API overview

`FirmataClient` (actor)

| Group | Methods |
|---|---|
| Lifecycle | `connect()`, `disconnect()`, `messages` (`AsyncStream<FirmataMessage>`), `lastDisconnectReason` |
| Digital | `setPinMode(_:mode:)`, `digitalWrite(pin:value:)`, `writeDigitalPort(_:pinMask:)`, `reportDigitalPort(_:enable:)` |
| Analog | `analogWrite(pin:value:)`, `extendedAnalogWrite(pin:value:)`, `reportAnalogPin(_:enable:)` |
| Queries | `queryProtocolVersion()`, `queryFirmware()`, `queryCapabilities()`, `queryAnalogMapping()`, `queryPinState(pin:)` |
| System | `systemReset()`, `setSamplingInterval(milliseconds:)`, `sendString(_:)` |
| I2C | `configureI2C(delayMicroseconds:)`, `i2cWrite(address:data:)`, `i2cReadOnce(address:register:count:)`, `i2cStartReading(...)`, `i2cStopReading(address:)` |
| Scheduler | `uploadTask(id:startDelayMs:repeatEveryMs:_:)`, `createTask(id:length:)`, `addToTask(id:data:)`, `scheduleTask(id:delayMs:)`, `deleteTask(id:)`, `resetTasks()`, `queryAllTasks()`, `queryTask(id:)` |

Custom transports conform to:

```swift
public protocol FirmataTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func openStream() -> AsyncThrowingStream<UInt8, Error>
}
```

## Firmware

Works with any standard Firmata firmware — flash
[StandardFirmata](https://github.com/firmata/arduino) or
[ConfigurableFirmata](https://github.com/firmata/ConfigurableFirmata) to your board.
The client speaks Firmata protocol v2.x over whichever transport you supply.

For the **original ESP32**, the companion
[**ESP32Firmata**](https://github.com/doraorak/ESP32Firmata) sketch is a single
firmware that speaks both built-in transports (Bonjour/TCP or BLE, selected at
compile time) and is byte-for-byte compatible with this client.

For the built-in transports the device should:

- **`BonjourTransport`** — advertise `_firmata._tcp` on the local network
  (ideally with `ip` and `port` TXT records, which let the client skip mDNS
  A-record resolution).
- **`BLETransport`** — expose the Nordic UART Service
  (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`), RX = write, TX = notify.

## Testing

```bash
swift test
```

## License

Released under the MIT License. See [LICENSE](LICENSE).
