# SwiftFirmataClient

A concurrency-safe Swift client for the Firmata protocol. Drive an ESP32 (or any
Firmata board) from macOS/iOS over Wi-Fi, BLE, TCP, or USB serial — and record
**tasks** that keep running on the board after you disconnect.

The client is an `actor`: every call is `async`, and all board→host traffic
arrives on one `messages` `AsyncStream`.

## The suite

| Repo | Role |
|---|---|
| [SwiftFirmataClient](https://github.com/doraorak/SwiftFirmataClient) | This package — the host-side client (macOS 13+ / iOS 16+, Swift 6) |
| [SwiftFirmataIR](https://github.com/doraorak/SwiftFirmataIR) | Optional IR (infrared) add-on package |
| [ESP32FirmataSwift](https://github.com/doraorak/ESP32FirmataSwift) | ESP32 firmware in Embedded Swift (ESP-IDF) |
| [ESP32Firmata](https://github.com/doraorak/ESP32Firmata) | The same firmware in C++ (Arduino) |

Both firmwares speak the identical wire protocol — use whichever toolchain you prefer.

## Install

```swift
.package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "16.0.0")
```

Pair with firmware **2.15+**.

## Quick start

```swift
import SwiftFirmataClient

let client = FirmataClient(transport: BonjourTransport())   // finds the board via mDNS
await client.connect()

try await client.setPinMode(.pin(2), mode: .output)
try await client.digitalWrite(pin: .pin(2), high: true)     // LED on

// A task the board runs by itself — forever, even with nobody connected:
try await client.uploadTask(id: 1, repeatEvery: .milliseconds(500)) { board in
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(250))
    board.digitalWrite(pin: .pin(2), high: false)
}
await client.disconnect()                                   // it keeps blinking
```

## Transports

| Transport | When to use it |
|---|---|
| `BonjourTransport()` | Same LAN — discovers `_firmata._tcp` via mDNS. Needs `NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist. |
| `TCPTransport(host:port:)` | Known address — static IP, another subnet, VPN, SSH tunnel. No discovery, no Info.plist keys. |
| `BLETransport()` | No network — Nordic UART Service. Needs `NSBluetoothAlwaysUsageDescription`. |
| `SerialTransport(path:)` | USB cable (macOS). The console port; opening it resets the board, so allow a moment before the first query. |

`FirmataTransport` is a two-requirement protocol (`send` + `openStream`) — implement
it to bring your own link. The board serves one master at a time, latest wins; an
evicted client receives an `EVICTED` notice and its stream ends.

## Live API — the host drives the board

- **Pins**: `setPinMode`, `digitalWrite`, `writeDigitalPort`, `analogWrite`,
  `extendedAnalogWrite`, `digitalRead`, `analogRead`
- **Servo**: `configureServo` (pulse range), `servoWrite` (0–180° or raw µs)
- **Streams**: `reportDigitalPort` / `reportAnalogChannel` + the `messages` stream;
  `setSamplingInterval`
- **Queries**: `queryFirmware`, `queryProtocolVersion`, `queryCapabilities`,
  `queryAnalogMapping`, `queryPinState`, `queryModules`
- **I²C**: `configureI2C`, `i2cWrite`, `i2cReadOnce`, `i2cStartReading` / `i2cStopReading`
- **Internet** (the board's Wi-Fi makes the request): `httpGet`, `httpPost`
- **Registers** (shared state with tasks): `setRegister`, `setFloatRegister`,
  `queryRegisters`
- **Wi-Fi provisioning** (encrypted X25519 + AES-GCM, over any transport):
  `provisionWiFi`, `queryWiFiStatus`, `forgetWiFi`
- **Tasks**: `uploadTask`, plus low-level `createTask` / `addToTask` / `scheduleTask`
  / `deleteTask` / `resetTasks` / `queryAllTasks` / `queryTask`

Pins and channels are typed — pass `.pin(n)` / `.channel(n)`, never a bare integer.

## Tasks — the board runs itself

`uploadTask { board in … }` hands you a `FirmataTaskRecorder` with the same verbs as
the live API, captured as bytes and executed on-device by the scheduler. Tasks
survive disconnects and live in RAM until deleted or reboot. Every recipe is in the
[COOKBOOK](COOKBOOK.md); the feature set:

- **Registers** — 32 shared `Int32` registers + 16 floats. `R0–R15` / `F0–F7` are
  **public** (yours, and how tasks share state with each other and the host via
  `setRegister`); `R16–R31` / `F8–F15` are **internal**, where value-producing ops
  auto-allocate their results so they never clobber your public registers. Pin an
  explicit public destination with `into: .reg(n)`.
- **Branches** — `ifTrue(a, .lessThan, b, then: { … }, elseDo: { … })`, nestable.
- **Repeat** — `repeat(times: 5, gap: .milliseconds(200)) { … }` runs a block exactly
  N times on-device (a native counted loop, nestable up to 4 deep).
- **Math** — `add` / `subtract` / `multiply` / `divide` / `modulo` + float variants
  (`÷0 → 0`).
- **Reads** — `digitalRead` / `analogRead`; `i2cRead` (register pointer + up to 4
  bytes, packed big-endian).
- **Internet + JSON** — `httpGet` / `httpPost` from the task, then inspect the body
  with `json.getNumber/getFloat/getString/getSize/getType/bodyContains`;
  `snapshot` / `free` retain a body across later requests.
- **Strings** — `string.createString/length/equals/contains/indexOf/toInt/free`.
- **Nested tasks** — `addTask(id:) { child in … }` uploads and schedules another task
  with no host involved; `deleteTask(id:)` stops one.
- **Telemetry** — `sendString` (task → host), `heapStats`.

## Modules

Optional hardware subsystems sit behind two generic primitives — `queryModules()` to
discover what the connected firmware has, and `sendToModule(id:payload:)` /
`FirmataTaskRecorder.moduleOp(id:payload:)` to talk to one. Each module ships as its
own package that depends on this one, adding typed extensions — import only what you need.

```swift
guard try await board.queryModules().contains(where: { $0.name == "ir" }) else { return }
```

| ID | Module | Purpose | Package |
|----|--------|---------|---------|
| `0x01` | `ir` | Infrared NEC/RC6 transmit + NEC receive | [SwiftFirmataIR](https://github.com/doraorak/SwiftFirmataIR) |

## Testing

`swift test` — 127 tests, no hardware needed: a `MockTransport` plays the board
(including the provisioning-crypto round-trip), and the recorder's byte output is
golden-tested against captures verified on real hardware.

## License

MIT — see [LICENSE](LICENSE).
