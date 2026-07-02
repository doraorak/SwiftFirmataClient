# SwiftFirmataClient

A concurrency-safe Swift client for the Firmata protocol. Drive an ESP32 (or any
Firmata board) from macOS/iOS over Wi-Fi, BLE, TCP, or USB serial — and record
**tasks** that keep running on the board after you disconnect.

The client is an `actor`; every call is `async`, and board→host traffic arrives
on one `AsyncStream`.

## The project suite

| Repo | Role |
|---|---|
| [SwiftFirmataClient](https://github.com/doraorak/SwiftFirmataClient) | This package — the host-side client (macOS 13+ / iOS 16+, Swift 6) |
| [ESP32FirmataSwift](https://github.com/doraorak/ESP32FirmataSwift) | ESP32 firmware in Embedded Swift (ESP-IDF, Xtensa) |
| [ESP32Firmata](https://github.com/doraorak/ESP32Firmata) | The same firmware in C++ (Arduino IDE / arduino-cli) |

Both firmwares speak the identical wire protocol; use whichever toolchain you prefer.

## Install

```swift
.package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "14.4.1")
```

## Quick start

```swift
import SwiftFirmataClient

let client = FirmataClient(transport: BonjourTransport())   // finds the board via mDNS
await client.connect()

try await client.setPinMode(2, mode: .output)
try await client.digitalWrite(pin: 2, high: true)           // LED on

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
| `TCPTransport(host:port:)` | Known address — static IP, another subnet, VPN/Tailscale, SSH tunnel. No discovery, no Info.plist keys. |
| `BLETransport()` | No network — Nordic UART Service. Needs `NSBluetoothAlwaysUsageDescription`. |
| `SerialTransport(path:)` | USB cable (macOS only; firmware 2.7+). The flashing/console port; opening it auto-resets the board, so allow a few seconds before the first query. |

`FirmataTransport` is a two-requirement protocol (`send` + `openStream`) — implement
it to bring your own link. The board accepts one master at a time, latest wins;
an evicted client receives an `EVICTED` notice and its stream ends.

## Live API (host drives the board)

- **Pins**: `setPinMode`, `digitalWrite`, `writeDigitalPort`, `analogWrite`,
  `extendedAnalogWrite`, `digitalRead`, `analogRead`
- **Streams**: `reportDigitalPort` / `reportAnalogChannel` + the `messages`
  stream; `setSamplingInterval`
- **Queries**: `queryFirmware`, `queryProtocolVersion`, `queryCapabilities`,
  `queryAnalogMapping`, `queryPinState`
- **I²C**: `configureI2C`, `i2cWrite`, `i2cReadOnce`, `i2cStartReading` / `i2cStopReading`
- **Internet** (the board's Wi-Fi makes the request): `httpGet`, `httpPost`
- **Wi-Fi provisioning** (encrypted X25519 + AES-GCM; works over any transport):
  `provisionWiFi`, `queryWiFiStatus`, `forgetWiFi`
- **Tasks**: `uploadTask` plus low-level `createTask` / `addToTask` /
  `scheduleTask` / `deleteTask` / `resetTasks` / `queryAllTasks` / `queryTask`

Typed identity wrappers (`.pin(n)` / `.channel(n)`) are available on the live
calls too, next to the plain-integer overloads.

## Tasks (the board runs itself)

`uploadTask { board in … }` hands you a `FirmataTaskRecorder`: the same verbs as
the live API, but captured as bytes and executed on-device by the Firmata
scheduler. Tasks survive disconnects; they live in RAM until deleted or reboot.

On top of standard Firmata scheduling, the firmwares add an extension
(ext ops `0x10–0x30` under the scheduler SysEx). Everything below records with
the same closure style — the [COOKBOOK](COOKBOOK.md) has a recipe per feature:

- **Registers**: 16 shared `Int32` registers `R0–R15` (bools are 0/1 in the same
  bank) + 8 floats `F0–F7`. Value-producing ops auto-allocate, or pin an explicit
  destination with `into: .reg(n)` — registers are global, so they're also how
  tasks share state with each other and with the host (`setRegister`).
- **Branches**: `ifTrue(a, .lessThan, b, then: { … }, elseDo: { … })`, nestable.
- **Math**: `add/subtract/multiply/divide/modulo` + float variants (`÷0 → 0`).
- **Reads**: `digitalRead`/`analogRead` into registers; `i2cRead` (register
  pointer + up to 4 bytes, packed big-endian).
- **Internet + JSON**: `httpGet`/`httpPost` from the task; inspect the response
  with `json.getNumber/getFloat/getString/getSize/getType/bodyContains`;
  `snapshot`/`free` persist a body across requests (12-slot pool: 2 JSON + 10 string).
- **Strings**: `string.createString/length/equals/contains/indexOf/toInt/free`.
- **Nested tasks**: `board.addTask(id:…) { child in … }` — a task uploads and
  schedules *another* task with no host involved; `board.deleteTask(id:)` stops
  one. Never reuse the enclosing task's own id.
- **Telemetry**: `sendString` (task → host), `heapStats`.

## Firmware compatibility

| Client feature | Needs firmware |
|---|---|
| `SerialTransport` (Firmata over USB) | ≥ 2.7.0 |
| Nested tasks (`addTask`/`deleteTask`), task `i2cRead`/`sendString` | ≥ 2.6.0 |
| Everything else in 14.x | ≥ 2.5.0 |

## Testing

`swift test` — 115 tests, no hardware needed (a `MockTransport` plays the board,
including the provisioning crypto round-trip). The recorder's byte output is
golden-tested against captures verified on real hardware.

## License

MIT — see [LICENSE](LICENSE).
