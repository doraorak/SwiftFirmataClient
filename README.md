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
| [ESP32FirmataSwift](https://github.com/doraorak/ESP32FirmataSwift) | ESP32 firmware in Embedded Swift (ESP-IDF) |
| [ESP32Firmata](https://github.com/doraorak/ESP32Firmata) | The same firmware in C++ (Arduino) |

Both firmwares speak the identical wire protocol — use whichever toolchain you prefer.
Optional hardware add-on packages (IR, sonar, DHT, display, mic) are listed under [Modules](#modules).

## Install

```swift
.package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "18.0.0")
```

Pair with firmware **2.27+** for everything below (the core works on 2.15+).

### Firmware compatibility

Both firmwares report the same `FIRMWARE_MAJOR.MINOR` — `queryFirmware()` tells you what a
board can do. Anything newer than the board's version fails at the wire, not at compile time.

| Firmware | Adds |
|---|---|
| **2.15** | Core: 32 int / 16 float registers, native `repeat`, the module subsystem, IR |
| **2.17** | `.pulldown` / `.touch` / `.dac` pin modes, `configurePWM`, sonar + DHT + display modules, task ops PWM-frequency / delay-operand / `once` |
| **2.18** | IR raw timings captured as text; compact 4×6 display font and line wrap |
| **2.19** | Task byte budget 512 → **4096** |
| **2.20** | One-shot sonar / DHT reads that answer the host directly (no register) |
| **2.21** | `.tone` pin mode + `TONE_CONFIG` (tone output is mode-gated) |
| **2.23** | Mic module — analog and I²S MEMS (INMP441) |
| **2.24** | Mic: settable I²S sample rate, on-device dominant frequency (FFT) |
| **2.27** | Display pixels, page blits and bitmap slots; **raw memory** read/write/info |

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
- **Raw memory** (firmware 2.27+): `queryMemoryInfo` (heap + the DRAM window),
  `readMemory`, `writeMemory` — a debugger's view of the board's RAM. Reads are
  range-checked on-device, so browsing is safe; **writes are live and can crash the
  board**
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

Optional hardware subsystems sit behind generic primitives — `queryModules()` to
discover what the connected firmware has, `sendToModule(id:payload:)` /
`FirmataTaskRecorder.moduleOp(id:payload:)` to talk to one, and
`sendToModuleAwaitingReply(id:payload:)` for request/reply ops (e.g. a one-shot sensor
read that answers directly). The modules add typed extensions on top of this package and live in
[SwiftFirmataModules](https://github.com/doraorak/SwiftFirmataModules) — one package with a
library product per module, so depending on it does not pull all five into your binary. Import
only what you need.

```swift
.package(url: "https://github.com/doraorak/SwiftFirmataModules", from: "1.0.0")
```

```swift
guard try await client.queryModules().contains(where: { $0.name == "ir" }) else { return }
```

| ID | Module | Purpose | Product |
|----|--------|---------|---------|
| `0x01` | `ir` | Infrared transmit/receive — NEC, RC6, Coolix, or raw; plus capture as text to learn a protocol | `SwiftFirmataIR` |
| `0x02` | `sonar` | HC-SR04 / US-100 ultrasonic distance → register | `SwiftFirmataSonar` |
| `0x03` | `dht` | DHT11 / DHT22 temperature & humidity → float registers | `SwiftFirmataDHT` |
| `0x04` | `display` | SSD1306 / SH1106 OLED — text, registers, strings; 5×7 or compact 4×6 font; pixels, whole frames and constant-size bitmap slots | `SwiftFirmataDisplay` |
| `0x05` | `mic` | Sound level from an analog or **I²S MEMS** mic (INMP441) → dB/RMS registers; on-device dominant-frequency (FFT) → Hz | `SwiftFirmataMic` |

## Testing

`swift test` — 138 tests, no hardware needed: a `MockTransport` plays the board
(including the provisioning-crypto round-trip), and the recorder's byte output is
golden-tested against captures verified on real hardware.

## License

MIT — see [LICENSE](LICENSE).
