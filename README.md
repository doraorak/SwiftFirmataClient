# SwiftFirmataClient

A modern, concurrency-safe [Firmata](https://github.com/firmata/protocol) client for Swift — talk to an Arduino, ESP32, or any Firmata-compatible board from macOS or iOS over **Bonjour/TCP** or **BLE**.

Built on Swift’s structured concurrency: the client is an `actor`, every public API is `async`, and incoming messages are delivered as an `AsyncStream`.

```swift
let client = FirmataClient(transport: BonjourTransport())
await client.connect()

let fw = try await client.queryFirmware()
print("Connected to \(fw.name) v\(fw.major).\(fw.minor)")

try await client.setPinMode(2, mode: .output)
try await client.digitalWrite(pin: 2, high: true)   // LED on
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
    t.digitalWrite(pin: 2, high: true)
    t.delay(ms: 250)
    t.digitalWrite(pin: 2, high: false)
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

### On-device logic (scheduler extension)

> An extension carried under the scheduler's reserved `EXTENDED_SCHEDULER_COMMAND`
> (`0x7F`) — the Scheduler control protocol is unchanged, and a standard Firmata
> scheduler ignores these ops gracefully (no crash; the conditionals are no-ops).
> Acted on only by this project's ESP32 firmware (`main` branch). The wire
> format is documented under *Custom protocol* below.

A task can also make decisions on the device, so it doesn't just replay a fixed
sequence. The board has **16 global Int32 registers**; load values into them and
branch with `ifTrue`:

```swift
// A night-light running entirely on the board, no client connected.
try await client.uploadTask(id: 3, repeatEveryMs: 1000) { t in
    t.setPinMode(2, mode: .output)
    t.readAnalog(into: 0, channel: 0)                 // R0 = analog A0
    t.ifTrue(.reg(0), .lessThan, .const(300),         // dark?
        then:   { $0.digitalWrite(pin: 2, high: true) },   // LED on
        elseDo: { $0.digitalWrite(pin: 2, high: false) })  // else off
}
```

- `setRegister(_:to:)`, `readDigital(into:pin:)`, `readAnalog(into:channel:)`
- `ifTrue(_:_:_:then:elseDo:)` — operands `.reg(0...15)` / `.const(value)`;
  comparisons `== != < > <= >=`. Forward-only (no loops), so a task can't hang the board.
- `channel` is an analog channel index (`A0 = 0`, …), **not** a pin number.

### Internet actions (scheduler extension)

A task can also **reach the internet over the board's Wi-Fi** — make an HTTP(S)
request and act on the result — so the device can talk to web services on its
own, with no host connected:

```swift
// Every minute, fetch a number from an endpoint and drive pin 2 when it's high.
try await client.uploadTask(id: 5, repeatEveryMs: 60_000) { t in
    t.setPinMode(2, mode: .output)
    t.httpGet("http://example.com/sensor", statusInto: 0, valueInto: 1)
    t.ifTrue(.reg(1), .greaterThan, .const(100),         // body's first number > 100?
        then:   { $0.digitalWrite(pin: 2, high: true) },
        elseDo: { $0.digitalWrite(pin: 2, high: false) })
}
```

- `httpGet(_:statusInto:valueInto:)` / `httpPost(_:body:statusInto:valueInto:)`.
  The device stores the **HTTP status** in `R[statusInto]` (`0` = Wi-Fi down /
  failure) and the **first integer found in the response body** in `R[valueInto]`,
  so later `ifTrue` steps can branch on internet data.
- If a host is connected while the task runs, the full result also arrives as
  `FirmataMessage.httpResponse(status:body:)` on the `messages` stream.

You can also fire a request **live** and await its result directly:

```swift
let r = try await client.httpGet("http://worldtimeapi.org/api/timezone/Etc/UTC")
print(r.status, r.body)                          // e.g. 200, {"...":"..."}
let p = try await client.httpPost("http://example.com/log", body: #"{"on":true}"#)
```

- The device performs the request and **blocks briefly** (up to ~8 s) while it
  does; `httpGet`/`httpPost` take a `timeout` (default 15 s).
- **URL/body must be ASCII** and fit one SysEx frame (URL + body ≲ 500 bytes).
- The body returned to the host is truncated by the device to a few hundred bytes
  (it's meant for status/short JSON, not large downloads).
- **HTTP only** in this build — `https://` needs the firmware's TLS (SSL) client
  enabled (see the firmware README).

#### Custom protocol — wire format (byte commands)

The logic ops are SysEx embedded in a task's data and replayed by the Scheduler,
under `SCHEDULER_DATA` (`0x7B`) → `EXTENDED_SCHEDULER_COMMAND` (`0x7F`). `<const>`
is an Int32 packed as 5 Encoder7Bit bytes; `<skip>` is a 14-bit count,
little-endian 7-bit (`skipLo skipHi`).

```
SET           F0 7B 7F 10 <reg> <const:5>                     F7   // R[reg] = const
READ_DIGITAL  F0 7B 7F 11 <reg> <pin>                         F7   // R[reg] = digitalRead(pin)
READ_ANALOG   F0 7B 7F 12 <reg> <channel>                     F7   // R[reg] = analogRead(channel)
IF            F0 7B 7F 13 <op> <operandA> <operandB> <skip:2> F7   // if !(A op B): pos += skip
SKIP          F0 7B 7F 14 <skip:2>                            F7   // pos += skip (else)
HTTP          F0 7B 7F 15 <method> <statusReg> <valueReg> <urlLen:2> <url…> <bodyLen:2> <body…> F7
```

- `<reg>`: register index, low nibble (`0`–`15`).
- `<op>`: `0 ==`, `1 !=`, `2 <`, `3 >`, `4 <=`, `5 >=`.
- `<operand>`: a type byte then data — `00 <reg>` (register) or `01 <const:5>` (literal).
- `if`/`else` layout: `[IF skip=thenLen] [then…] [SKIP skip=elseLen] [else…]` — a
  false `IF` skips the then-block (landing on `else`); a true one runs `then`,
  whose trailing `SKIP` jumps over `else`.
- `HTTP` (`0x15`): `<method>` `0`=GET `1`=POST; `<statusReg>`/`<valueReg>` are
  register indices; `<urlLen>`/`<bodyLen>` are 14-bit little-endian (`lo hi`);
  `<url>`/`<body>` are raw 7-bit ASCII. The device sets `R[statusReg]` = HTTP
  status (`0` on failure) and `R[valueReg]` = first integer in the body. POST
  sends `Content-Type: application/json`.

The device replies (only when a host is connected) with the result:

```
HTTP_REPLY    F0 7B 0B <status:2> <body 14-bit LSB/MSB pairs…> F7   // device -> host
```
`<status:2>` is the HTTP code as `lo hi`; the body follows as `STRING_DATA`-style
14-bit pairs. Parsed by the client into `FirmataMessage.httpResponse(status:body:)`.

The base Scheduler messages (`CREATE_TASK` `0x00`, `ADD_TO_TASK` `0x02`,
`SCHEDULE_TASK` `0x04`, `DELAY_TASK` `0x03`, `QUERY` `0x05`/`0x06`, `RESET` `0x07`)
are unchanged from standard Firmata.

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
| Digital | `setPinMode(_:mode:)`, `digitalWrite(pin:high:)`, `writeDigitalPort(_:pinMask:)`, `reportDigitalPort(_:enable:)` |
| Analog | `analogWrite(channel:value:)`, `extendedAnalogWrite(pin:value:)`, `reportAnalogPin(_:enable:)` |
| Queries | `queryProtocolVersion()`, `queryFirmware()`, `queryCapabilities()`, `queryAnalogMapping()`, `queryPinState(pin:)` |
| System | `systemReset()`, `setSamplingInterval(milliseconds:)`, `sendString(_:)` |
| I2C | `configureI2C(delayMicroseconds:)`, `i2cWrite(address:data:)`, `i2cReadOnce(address:register:count:)`, `i2cStartReading(...)`, `i2cStopReading(address:)` |
| Live reads | `digitalRead(pin:timeout:) -> Bool`, `analogRead(channel:timeout:) -> UInt16` |
| Scheduler | `uploadTask(id:startDelayMs:repeatEveryMs:_:)`, `createTask(id:length:)`, `addToTask(id:data:)`, `scheduleTask(id:delayMs:)`, `deleteTask(id:)`, `resetTasks()`, `queryAllTasks()`, `queryTask(id:)` |
| **Extension¹** — internet | `httpGet(_:timeout:) -> HTTPResponse`, `httpPost(_:body:timeout:) -> HTTPResponse` |

`FirmataTaskRecorder` (used inside `uploadTask`) mirrors the writes — `setPinMode`,
`digitalWrite(pin:high:)`, `analogWrite(channel:value:)`, `delay(ms:)` — plus the
**extension¹** ops: `setRegister`, `readDigital(into:)`/`digitalRead(pin:)`,
`readAnalog(into:)`/`analogRead(channel:)`, `ifTrue(_:_:_:then:elseDo:)`,
`httpGet(_:statusInto:valueInto:)`, `httpPost(_:body:statusInto:valueInto:)`.

> **¹ Non-standard extension — requires supported firmware.** The on-device logic
> (registers / `if`-`else`) and internet actions are **not part of standard Firmata**.
> They ride under the Scheduler's reserved `EXTENDED_SCHEDULER_COMMAND` (`0x7F`) so a
> stock Firmata board *ignores them harmlessly*, but they only **do** anything on
> firmware that implements this project's extension — see [Firmware](#firmware).

Custom transports conform to:

```swift
public protocol FirmataTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func openStream() -> AsyncThrowingStream<UInt8, Error>
}
```

## Firmware

**Two tiers of functionality:**

1. **Standard Firmata (any firmware).** Pin I/O, queries, I2C, the base Scheduler,
   strings, sampling — these work with **any** standard Firmata firmware
   ([StandardFirmata](https://github.com/firmata/arduino) /
   [ConfigurableFirmata](https://github.com/firmata/ConfigurableFirmata)) over
   whichever transport you supply. The client speaks Firmata protocol v2.x.

2. **Extension features (require *this project's* firmware).** The on-device
   **logic extension** (16 registers, `readDigital`/`readAnalog`, `ifTrue`) and
   **internet actions** (`httpGet`/`httpPost`, live and in tasks) are a
   **non-standard extension**. They are carried under the Scheduler's reserved
   `EXTENDED_SCHEDULER_COMMAND` (`0x7F`), so a stock Firmata board **ignores them
   without error** — but nothing happens unless the firmware implements the
   extension (and, for internet actions, has Wi-Fi). Calling `httpGet` against
   unsupported firmware simply times out; a logic task degrades to its no-op
   parts.

**Firmware that supports the extension** (both byte-for-byte compatible with this
client, both implement the logic extension **and** internet actions):

- [**ESP32Firmata**](https://github.com/doraorak/ESP32Firmata) — the Arduino/C++
  sketch for the original ESP32 (Wi-Fi/TCP + Bonjour **and** BLE in one build).
- [**ESP32FirmataSwift**](https://github.com/doraorak/ESP32FirmataSwift) — an
  Embedded-Swift port of the same firmware.

> Internet actions need Wi-Fi on the board and currently support **`http://` only**
> (`https://` needs a TLS client built into the firmware — see the firmware READMEs).

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
