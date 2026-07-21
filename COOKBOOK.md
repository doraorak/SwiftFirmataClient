# SwiftFirmataClient Cookbook

Task-oriented recipes for every feature in the suite — the host-side `FirmataClient`,
the on-device task recorder, and all five vendored hardware modules (IR, Sonar, DHT,
Display, Mic). Each section is self-contained: a short "what it is", runnable snippets, and a
**Tips** / **Caveats** block where the sharp edges live.

> **Conventions.** `client` is a connected `FirmataClient`; inside `uploadTask { board in … }`,
> `board` is the `FirmataTaskRecorder` (calls are recorded, not sent — synchronous, no `await`). Every live call is `async throws`.
> Pins and channels are typed — pass `.pin(n)` / `.channel(n)`, never a bare integer. Snippets
> assume `import SwiftFirmataClient` (plus the module package where relevant).

> **Firmware floor.** The core works on firmware **2.15+**. Feature minimums: modules **2.16+**,
> raw-capture sniff & `once { }` **2.17+**, IR raw-text capture **2.18+**, the mic module (RMS→dB) **2.22+** (digital I²S MEMS mic **2.23+**; settable I²S rate + dominant-frequency FFT **2.24+**), the **4096-byte task
> budget 2.19+** (older firmware caps a single task at 512 bytes), one-shot sonar/dht reads
> **2.20+** (sonar/dht module 1.1), `.tone` pin mode + `toneWrite` **2.21+**. `queryFirmware()` /
> `queryModules()` tell you what's running.

---

## Contents

**Host drives the board (live)**
1. [Connecting](#1-connecting) · 2. [The messages stream](#2-the-messages-stream) ·
3. [Digital & analog I/O](#3-digital--analog-io) · 4. [Pin modes, PWM, tone, DAC](#4-pin-modes-pwm-tone-dac) ·
5. [Servo](#5-servo) · 6. [Input streams & sampling](#6-input-streams--sampling) ·
7. [Queries & capabilities](#7-queries--capabilities) · 8. [I²C](#8-ic) ·
9. [Internet requests](#9-internet-requests-live) · 10. [Wi-Fi provisioning](#10-wi-fi-provisioning) ·
11. [Registers (live)](#11-registers-live--the-shared-state-model)

**The board runs itself (tasks)**
12. [Tasks — upload & manage](#12-tasks--upload--manage) · 13. [The recorder — basic verbs](#13-the-recorder--the-basic-verbs) ·
14. [Operands & the value model](#14-operands--the-value-model) · 15. [Branches](#15-branches) ·
16. [Repeat & Once](#16-repeat--once) · 17. [Arithmetic](#17-arithmetic) ·
18. [On-device reads](#18-on-device-reads) · 19. [Internet & JSON in a task](#19-internet--json-in-a-task) ·
20. [Strings](#20-strings) · 21. [Nested tasks](#21-nested-tasks) · 22. [Telemetry & heap](#22-telemetry--heap)

**Extending & modules**
23. [Custom transports](#23-custom-transports) · 24. [Modules — discovery & the generic primitive](#24-modules--discovery--the-generic-primitive) ·
25. [IR module](#25-ir-module) · 26. [Sonar module](#26-sonar-module) · 27. [DHT module](#27-dht-module) ·
28. [Display module](#28-display-module) · 29. [Mic module](#29-mic-module)

**Reference**
30. [Global caveats & gotchas](#30-global-caveats--gotchas) · 31. [Type reference](#31-type-reference)

---

## 1. Connecting

`FirmataClient` is an `actor`. Construct it with a transport, `connect()`, and you're driving a board.

```swift
let client = FirmataClient(transport: BonjourTransport())   // mDNS discovery on the LAN
await client.connect()
defer { Task { await client.disconnect() } }

let fw = try await client.queryFirmware()      // handshake round-trip
print("\(fw.name) \(fw.major).\(fw.minor)")   // e.g. "ESP32Firmata 2.19"
```

Pick a transport for how the board is reachable (full table in [§23](#23-custom-transports)):

```swift
FirmataClient(transport: BonjourTransport())              // same LAN, auto-discover
FirmataClient(transport: TCPTransport(host: "192.168.1.42", port: 3030))
FirmataClient(transport: BLETransport())                  // no network — Nordic UART
FirmataClient(transport: SerialTransport(path: "/dev/cu.wchusbserial110"))  // USB
```

**Tips**
- Treat `connect()` as once-per-session, and always `disconnect()` when done or the board keeps you as its master.
- The board serves **one master at a time, latest wins**. A new client evicts the previous one, which gets an `EVICTED` notice and whose `messages` stream ends ([§2](#2-the-messages-stream)).
- Do a `queryFirmware()` right after connecting: it confirms the link and tells you the firmware version so you can gate features.

**Caveats**
- `SerialTransport` opens the ESP32's console port, which **resets the board** on open. Wait a beat before the first query.
- `BonjourTransport` needs `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_firmata._tcp`); `BLETransport` needs `NSBluetoothAlwaysUsageDescription`. `TCPTransport` needs neither.

---

## 2. The messages stream

All board→host traffic that isn't the direct reply to an `async` call arrives on one `AsyncStream`:
streamed pin values, string telemetry, and module events.

```swift
Task {
    for await message in await client.messages {
        switch message {
        case let .digital(port, mask):        print("port \(port) = \(mask)")
        case let .analog(channel, value):     print("A\(channel) = \(value)")
        case let .stringData(text):           print("board says: \(text)")
        case let .moduleEvent(id, payload):   print("module \(id): \(payload)")
        default: break
        }
    }
    // Stream ended → the board evicted us, or we disconnected.
}
```

Module packages add typed accessors on `FirmataMessage` so you never hand-decode a payload:

```swift
if let code = message.module.ir.code { print("IR frame: \(String(code, radix: 16))") }
```

**Tips**
- Start the consuming `Task` **before** you enable any stream ([§6](#6-input-streams--sampling)) so you don't miss the first samples.
- There is exactly one stream per client — fan out yourself if several parts of your app care.

**Caveats**
- Direct replies (`queryFirmware`, `analogRead`, `httpGet`, …) do **not** appear here — they return from their `async` call. `messages` is only asynchronous/streamed traffic.
- When the stream ends, it's terminal. Reconnect and re-read `messages` for a fresh one.

---

## 3. Digital & analog I/O

```swift
try await client.setPinMode(.pin(2), mode: .output)
try await client.digitalWrite(pin: .pin(2), high: true)     // LED on

try await client.setPinMode(.pin(4), mode: .input)          // or .inputPullup / .inputPulldown
let pressed = try await client.digitalRead(pin: .pin(4))     // one-shot, waits for a report

let light = try await client.analogRead(channel: .channel(0)) // 0–4095 on the ESP32 ADC

try await client.analogWrite(channel: .channel(2), value: 512)  // 8-bit PWM via analog channel map
try await client.extendedAnalogWrite(pin: .pin(25), value: 4095) // wide values / high pins
```

Write a whole 8-pin port at once with a mask:

```swift
try await client.writeDigitalPort(0, pinMask: 0b0000_1010)   // set pins 1 & 3 of port 0
```

**Tips**
- `digitalRead`/`analogRead` are **one-shot**: they enable reporting, wait for the next report, then return. For continuous values use streams ([§6](#6-input-streams--sampling)) — far less traffic than polling.
- `extendedAnalogWrite` takes an `Int32` and a **pin**, so it reaches high GPIOs and values beyond 8-bit.

**Caveats**
- ESP32 ADC is 12-bit (`0–4095`) and non-linear near the rails.
- `digitalRead`/`analogRead` throw `FirmataError.noResponse` if no report arrives within `timeout` (default 2 s) — e.g. you forgot `setPinMode`.

---

## 4. Pin modes, PWM, tone, DAC

`PinMode` is the full Firmata set plus three ESP32 extensions (firmware 2.16+):

| Mode | Use |
|---|---|
| `.input` `.inputPullup` `.inputPulldown` | digital in; internal pull-up / pull-down |
| `.output` | digital out |
| `.analog` | ADC read |
| `.pwm` | LEDC PWM out |
| `.servo` | servo pulse |
| `.dac` | true 8-bit analog out (GPIO 25/26 only) |
| `.touch` | capacitive touch (reads on analog channels 6–15, i.e. T0–T9) |
| `.i2c` `.tone` `.sonar` `.dht` … | subsystem pins |

```swift
// Explicit PWM frequency & resolution, then drive it:
try await client.configurePWM(pin: .pin(5), frequencyHz: 1000, resolutionBits: 10) // 0–1023 @ 1 kHz
try await client.extendedAnalogWrite(pin: .pin(5), value: 768)

// True analog out (DAC), 0–255 — dacWrite is gated on .dac mode:
try await client.setPinMode(.pin(25), mode: .dac)
try await client.dacWrite(pin: .pin(25), value: 200)         // or extendedAnalogWrite(pin:value:)

// Capacitive touch — touchRead is gated on .touch mode:
try await client.setPinMode(.pin(4), mode: .touch)           // T0 is GPIO 4
let t = try await client.touchRead(pin: .pin(4))             // lower = touched

// Tone (passive buzzer) — toneWrite is gated on .tone mode:
try await client.setPinMode(.pin(13), mode: .tone)
try await client.toneWrite(pin: .pin(13), hz: 880)           // continuous — stop with hz: 0
try await client.toneWrite(pin: .pin(13), hz: 440, for: .milliseconds(200))  // beep, auto-stops
```

**Tips**
- **Mode-gated writes**, just like `analogWrite` needs `.pwm`: `toneWrite`/`dacWrite`/`touchRead` require the pin in `.tone`/`.dac`/`.touch` mode (set with `setPinMode` first) and throw `FirmataError.invalidData` otherwise — the client mirrors the firmware's route-by-mode.
- `toneWrite(hz:)` is continuous (like `analogWrite` sets a value); `toneWrite(hz:for:)` auto-stops on-device after the duration. `hz: 0` silences.
- `.inputPulldown` is genuinely useful on the ESP32 (classic AVR Firmata has none). GPIO 34–39 are input-only with **no** internal pulls.
- Touch values *drop* when touched. Calibrate an idle baseline, then threshold below it.

**Caveats**
- DAC exists only on GPIO 25 & 26; `.dac` elsewhere is a no-op. Tone frequency is capped at ~16 kHz (14-bit); durations at ~16 s.
- Changing a pin's mode mid-PWM/tone stops the output. Set mode → configure → write.
- `PinMode` lists only the modes this firmware implements (input/output/analog/pwm/servo/i2c/pullup/pulldown/touch/dac/tone). Standard-but-unimplemented modes (serial/spi/stepper/…) and the sensor subsystems (sonar/dht) are **not** pin modes here — the sensors are [modules](#24-modules--discovery--the-generic-primitive).

---

## 5. Servo

```swift
try await client.configureServo(pin: .pin(9),
                               minPulseMicros: 544,   // defaults shown
                               maxPulseMicros: 2400)
try await client.servoWrite(pin: .pin(9), value: 90)   // 0–180°
try await client.servoWrite(pin: .pin(9), value: 1500) // >180 is treated as raw microseconds
```

**Tips**
- Set the pulse envelope for *your* servo — cheap SG90s often want `500…2400`. A wrong envelope means it can't reach its ends or buzzes at the stops.
- Values `0…180` are degrees; values above `180` are raw µs, handy for fine trim.

**Caveats**
- Servos draw current spikes — power them from a separate 5 V supply with a common ground, not the ESP32 regulator.

---

## 6. Input streams & sampling

Instead of polling, tell the board to *report* and read the `messages` stream ([§2](#2-the-messages-stream)):

```swift
try await client.setSamplingInterval(.milliseconds(50))       // analog cadence (default ~19 ms)
try await client.reportAnalogChannel(.channel(0), enable: true)
try await client.reportDigitalPort(0, enable: true)           // all 8 pins of port 0

for await m in await client.messages {
    if case let .analog(0, v) = m { print("A0 = \(v)") }
}
// later:
try await client.reportAnalogChannel(.channel(0), enable: false)
```

**Tips**
- Digital reporting is **per port** (8 pins), analog **per channel**. The board emits a digital frame only when a pin in that port *changes*, so idle inputs cost nothing.
- Widen `setSamplingInterval` to cut BLE/serial traffic; narrow it for snappier analog.

**Caveats**
- Too many analog channels at a tight interval can flood a BLE link. Start at 50 ms.

---

## 7. Queries & capabilities

```swift
let v    = try await client.queryProtocolVersion()   // Firmata protocol major.minor
let fw   = try await client.queryFirmware()           // name + firmware version
let caps = try await client.queryCapabilities()       // [[PinCapability]] — modes per pin
let map  = try await client.queryAnalogMapping()      // channel → pin
let st   = try await client.queryPinState(pin: .pin(2))
let mods = try await client.queryModules()            // what hardware modules are present
```

**Tips**
- `queryCapabilities()` is the ground truth for "can this pin do PWM/servo/analog?" — use it before assuming a pinout.
- Gate every module and every 2.16+/2.17+/2.18+/2.19+ feature on `queryFirmware()` / `queryModules()`.

---

## 8. I²C

```swift
try await client.configureI2C()                       // optional bus delay
try await client.i2cWrite(address: 0x3C, data: [0x00, 0xAF]) // command bytes

// Read 6 bytes from register 0x00 of device 0x68 (e.g. an MPU-6050):
let reply = try await client.i2cReadOnce(address: 0x68, registerAddress: 0x00, count: 6)
print(reply.data)

// Continuous reads → messages stream:
try await client.i2cStartReading(address: 0x68, registerAddress: 0x3B, count: 6)
try await client.i2cStopReading(address: 0x68)
```

**Tips**
- `registerAddress` is optional — omit for devices without a register pointer.
- For 10-bit addressing pass `is10Bit: true` on every call for that device.
- Tasks can read I²C into a register too ([§18](#18-on-device-reads)).

**Caveats**
- ESP32 default I²C pins are GPIO 21 (SDA) / 22 (SCL). Wire/mode accordingly.

---

## 9. Internet requests (live)

The **board's own Wi-Fi** makes the request; you get status + body back.

```swift
let res = try await client.httpGet("http://worldtimeapi.org/api/timezone/Etc/UTC")
print(res.status, res.body)

let post = try await client.httpPost("http://example.com/log",
                                    body: #"{"temp":21.4}"#,
                                    timeout: .seconds(20))
```

**Tips**
- The point of an internet-of-things board: move this into a task and no host is needed at request time ([§19](#19-internet--json-in-a-task)).
- Bump `timeout` for slow endpoints; default is 15 s.

**Caveats**
- Provision Wi-Fi first ([§10](#10-wi-fi-provisioning)) or the request fails immediately.
- HTTPS depends on the firmware's mbedTLS config; plain `http://` always works. Bodies are truncated to the firmware's 4 KB parse buffer ([§19](#19-internet--json-in-a-task)).

---

## 10. Wi-Fi provisioning

Hand the board Wi-Fi credentials over **any** transport (including BLE, before it has a network).
The exchange is encrypted end-to-end (X25519 key agreement → HKDF → AES-GCM); the password never
crosses the wire in clear text.

```swift
let status = try await client.provisionWiFi(ssid: "MyNetwork", password: "hunter2")
print(status.connected, status.ip ?? "—")

let cur = try await client.queryWiFiStatus()
try await client.forgetWiFi()     // clear stored credentials
```

**Tips**
- Provision once over USB or BLE; the board stores credentials in flash and reconnects on boot.
- `queryWiFiStatus()` returns the IP once associated — grab it to switch to a faster `TCPTransport`.

**Caveats**
- `provisionWiFi` defaults to a 25 s timeout because association is slow; raise it on congested networks.

---

## 11. Registers (live) — the shared-state model

Registers are the board's variables — the one piece of state the host, tasks, and modules all
share. There are **32 integer registers** (`R0–R31`, `Int32`) and **16 float registers**
(`F0–F15`).

| Bank | Integers | Floats | Who owns it |
|---|---|---|---|
| **Public** | `R0–R15` | `F0–F7` | **Yours.** Set from the host, read from tasks, point results here explicitly. |
| **Internal** | `R16–R31` | `F8–F15` | Auto-allocated scratch for value-producing task ops, so they never clobber your public registers. |

```swift
try await client.setRegister(3, to: 42)        // R3 = 42   (public bank, 0–15)
try await client.setFloatRegister(0, to: 21.5) // F0 = 21.5 (public bank, 0–7)

let snap = try await client.queryRegisters()
print(snap.ints[3], snap.floats[0])           // 42, 21.5
```

**Tips**
- Registers are how a **module feeds a task**: a sonar ping writes distance to `R5`, a task reads `R5` and reacts — with nobody connected. Same for DHT (float regs) and IR receive (int reg).
- Poll `queryRegisters()` to watch on-device state evolve (a sonar `autoPing`, a running task's counter…).

**Caveats**
- Live `setRegister`/`setFloatRegister` address the **public bank only** (`0–15` / `0–7`). The internal bank is reachable only as auto-allocated task results.
- Registers live in RAM: they survive disconnects but **not** reboot.

---

## 12. Tasks — upload & manage

A **task** is a byte-compiled program the board's scheduler runs on its own — surviving disconnects,
living in RAM until deleted or reboot. The recorder ([§13](#13-the-recorder--the-basic-verbs)) captures
verbs as bytes; `uploadTask` ships and schedules them.

```swift
try await client.uploadTask(id: 1, repeatEvery: .milliseconds(500)) { board in
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(250))
    board.digitalWrite(pin: .pin(2), high: false)
}
await client.disconnect()          // it keeps blinking

// Low-level control:
try await client.deleteTask(id: 1)
try await client.resetTasks()                       // wipe all tasks
let ids = try await client.queryAllTasks()          // [UInt8] of scheduled ids
let t   = try await client.queryTask(id: 1)         // read one back (bytes included)
```

`uploadTask` is sugar over the primitives, if you need them:

```swift
try await client.createTask(id: 2, length: bytes.count)
try await client.addToTask(id: 2, data: bytes)      // client splits into 48-byte chunks
try await client.scheduleTask(id: 2, delay: .seconds(1))
```

**Tips**
- `repeatEvery:` makes the task re-arm itself forever; omit it for a one-shot.
- Use small integer `id`s (0–7). Reusing an id replaces the task.
- Combine with [§16](#16-repeat--once): a `repeatEvery` task whose body runs a `once { }` setup on the first pass only.

**Caveats**
- A single task's compiled bytes must fit the **task budget: 4096 bytes on firmware 2.19+** (512 on older firmware). `uploadTask` throws if you exceed it. Big tasks are usually big because of long literal strings ([§20](#20-strings)) or many HTTP/JSON ops ([§19](#19-internet--json-in-a-task)).
- Up to **8 tasks** run concurrently.
- Tasks are RAM-resident: a reboot clears them. Re-upload on reconnect for persistence.

---

## 13. The recorder — the basic verbs

Inside `uploadTask { board in … }`, `board` is a `FirmataTaskRecorder` with the same verbs as the
live API — but they *record* instead of executing. The recorder is **synchronous** (no `await`).

```swift
try await client.uploadTask(id: 3, repeatEvery: .seconds(1)) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.digitalWrite(pin: .pin(2), high: true)
    board.analogWrite(channel: .channel(2), value: 512)
    board.extendedAnalogWrite(pin: .pin(25), value: 200)
    board.servoWrite(pin: .pin(9), value: 90)
    board.configurePWM(pin: .pin(5), frequencyHz: 1000)
    board.tone(pin: .pin(13), hz: 2000, duration: .milliseconds(200))
    board.delay(.milliseconds(500))
}
```

Most verbs also accept **operands** ([§14](#14-operands--the-value-model)) so they use runtime values:

```swift
board.digitalWrite(pin: .pin(2), high: .boolReg(0))   // pin follows R0
board.analogWrite(pin: .pin(5), value: .reg(1))       // duty from R1
board.servoWrite(pin: .pin(9), value: .reg(2))        // angle from R2
board.delay(.reg(3))                                   // delay ms from R3
board.tone(pin: .pin(13), hz: .reg(4), duration: .number(100))
board.configurePWM(pin: .pin(5), frequency: .reg(5))
```

**Tips**
- Anything the live API does one-shot, the recorder does on the board's schedule. Recording `setPinMode` inside the task makes it self-contained.
- The operand overloads turn a static blink into a *reactive* program — pin state, PWM duty, delay, and tone all driven by registers a sensor writes.

**Caveats**
- The recorder can't *return a value to your Swift code* — it has no channel at record time. On-device reads land in registers ([§18](#18-on-device-reads)); to see them, `queryRegisters()` live or display them ([§28](#28-display-module)).

---

## 14. Operands & the value model

An **operand** is a typed value a task op consumes at runtime. Three value kinds — integer, float,
boolean — each either a **literal** (baked into the bytes) or a **register** (read on-device when
the op runs):

| Factory | Meaning |
|---|---|
| `.number(42)` | integer literal (`Int32`) |
| `.reg(3)` | integer register `R3` (public 0–15) |
| `.float(1.5)` | float literal |
| `.freg(0)` | float register `F0` (public 0–7) |
| `.bool(true)` | boolean literal (compared as `1`/`0`) |
| `.boolReg(4)` | integer register reinterpreted as boolean (`0`/non-zero) |

Value-producing ops (`add`, `analogRead`, `json.getNumber`, `string.length`, …) return a typed
handle *and* write their result into a register. Without `into:` they auto-allocate an **internal**
register (`R16–31` / `F8–15`); with `into:` you pin a public one:

```swift
let sum = board.add(.reg(0), .number(10))            // → internal register, returned as TaskNumber
board.add(.reg(0), .number(10), into: .reg(1))       // → R1 explicitly

let hot = board.digitalRead(pin: .pin(4))            // TaskBool handle
board.ifTrue(hot, then: { $0.digitalWrite(pin: .pin(2), high: true) })
```

**Tips**
- Chain producers by feeding one op's returned handle straight into the next — no register bookkeeping; the internal bank keeps them apart.
- Reach for `into:` only when the host or another task needs that result (put it in the public bank).

**Caveats**
- `.reg(n)`/`.freg(n)` address the public bank (`0–15` / `0–7`). Internal registers are for op results, not hand-addressing.
- Booleans are integers under the hood — `.bool` compares as `1`/`0`, `.boolReg` treats any non-zero as true.

---

## 15. Branches

`ifTrue` runs a block when a comparison (or a boolean operand) holds. Nestable, with an optional `elseDo`.

```swift
board.ifTrue(.reg(0), .greaterThan, .number(100),
             then:   { $0.digitalWrite(pin: .pin(2), high: true) },
             elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })

// Boolean-operand form (from a predicate op):
let present = board.digitalRead(pin: .pin(4))
board.ifTrue(present, then: { $0.tone(pin: .pin(13), hz: 1000, duration: .milliseconds(100)) })

// Materialise a comparison into a register for reuse:
let over = board.compare(.reg(0), .greaterThanOrEqual, .number(50))
board.ifTrue(over, then: { … })
```

`TaskComparison`: `.equal` `.notEqual` `.lessThan` `.greaterThan` `.lessThanOrEqual` `.greaterThanOrEqual`.

**Tips**
- Comparisons work on int *and* float operands — mix `.freg(0)` with `.float(28)` for a thermostat.
- `compare(...)` gives a reusable `TaskBool` when one condition gates several blocks.

**Caveats**
- `elseDo` is a real second block on the wire; deeply nested if/else grows the byte count — mind the task budget ([§12](#12-tasks--upload--manage)).

---

## 16. Repeat & Once

**Repeat** runs a block a fixed number of times on-device — a native counted loop, not unrolled
bytes, so 1000 iterations cost the same as 5. Nestable up to **4 deep**.

```swift
board.`repeat`(times: 5, gap: .milliseconds(200)) { board in
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(100))
    board.digitalWrite(pin: .pin(2), high: false)
}
```

**Once** (firmware 2.17+) runs a block a single time across the whole life of the task — even when
the task repeats. Ideal for one-time setup inside a `repeatEvery` task (arming a receiver, seeding
a register):

```swift
try await client.uploadTask(id: 4, repeatEvery: .milliseconds(200)) { board in
    board.once { b in
        b.irReceiveNEC(pin: .pin(18), into: .reg(0))   // arm the receiver exactly once
        b.setRegister(.reg(1), to: .number(0))          // seed a counter once
    }
    board.ifTrue(.reg(0), .equal, .number(0x20DF10EF),
                 then: { $0.add(.reg(1), .number(1), into: .reg(1)) })
}
```

**Tips**
- `gap:` on `repeat` is the pause *between* iterations (not after the last). Use it for debounced pulses.
- Registers written inside `once { }` are visible to the rest of the task — the once scope guards *execution*, not *state*.

**Caveats**
- Don't re-arm a module receiver every pass of a repeating task — wrap it in `once { }`, or you reset the module's capture state on every tick and it "only reads the first frame." The single most common IR-receive bug ([§25](#25-ir-module)).
- Repeat nesting is capped at 4; deeper nests are rejected at record time.

---

## 17. Arithmetic

Integer and float, each writing to a register (auto-internal, or `into:` for public):

```swift
board.add(.reg(0), .number(1), into: .reg(0))         // R0 += 1
board.subtract(.reg(0), .reg(1))                       // → internal
board.multiply(.reg(0), .number(3))
board.divide(.reg(0), .number(2))                      // integer divide
board.modulo(.reg(0), .number(10))

board.addFloat(.freg(0), .float(0.5), into: .freg(0))
board.subtractFloat(.freg(0), .freg(1))
board.multiplyFloat(.freg(0), .float(1.8))
board.divideFloat(.freg(0), .float(0))                 // ÷0 → 0 (no trap)
```

**Tips**
- Combine `once { }` to seed and `repeatEvery` to accumulate — a task-side counter or running value with no host.
- Use `into: .reg(n)` when the host will read the total via `queryRegisters()`.

**Caveats**
- Integer `divide`/`modulo` are integer math; `÷0` yields `0` rather than trapping. Float `÷0` also yields `0`.

---

## 18. On-device reads

Reads that land in a register for a task to act on:

```swift
board.digitalRead(into: .boolReg(0), pin: .pin(4))     // R0 = pin level
board.analogRead(into: .reg(1), channel: .channel(0))  // R1 = ADC value
board.i2cRead(address: 0x68, registerAddress: 0x3B, count: 2, into: .reg(2)) // big-endian

// Or the operand-returning forms for immediate use:
let level = board.digitalRead(pin: .pin(4))            // TaskBool
let light = board.analogRead(channel: .channel(0))     // TaskNumber
board.ifTrue(light, .lessThan, .number(500),
             then: { $0.digitalWrite(pin: .pin(2), high: true) })
```

**Tips**
- `i2cRead` packs up to 4 bytes big-endian into one `Int32` register — perfect for a 16-bit sensor word.
- The operand-returning forms auto-allocate an internal register, so you can branch on a read without naming one.

**Caveats**
- `i2cRead` is limited to ≤ 4 bytes into one register. For longer reads, stream over the live API ([§8](#8-ic)).

---

## 19. Internet & JSON in a task

The board fetches a URL and inspects the JSON body **entirely on-device** — the payoff feature for
an offline gadget. `httpGet`/`httpPost` return a `TaskHTTPResponse` (a status register + a body
handle); the `json` ops read fields from that body.

```swift
try await client.uploadTask(id: 5, repeatEvery: .minutes(10)) { board in
    let res = board.httpGet("http://api.example.com/weather", statusInto: .reg(0))

    // Numbers (optionally scaled to keep decimals as an int), floats, strings, structure:
    board.json.getNumber(res.body, "main.temp", scaledBy: 1, into: .reg(1))   // 21.4 → 214
    board.json.getFloat(res.body, "main.humidity", into: .freg(0))
    let city = board.json.getString(res.body, "name")                         // TaskString
    board.json.getType(res.body, "weather.0", into: .reg(2))                  // 2 = array…
    board.json.getSize(res.body, "weather", into: .reg(3))                    // element count
    board.ifTrue(board.json.bodyContains(res.body, "Rain"),
                 then: { $0.digitalWrite(pin: .pin(2), high: true) })

    // Keep a body across later requests:
    board.json.snapshot(res.body, into: TaskJSONSlot(0))
    board.json.free(res.body)
}
```

**Tips**
- `scaledBy:` multiplies by `10^n` before truncating, so `getNumber("temp", scaledBy: 2)` keeps two decimals as an integer you can compare exactly.
- `snapshot` retains a parsed body so a *later* request doesn't invalidate the fields you still need; `free` releases it.
- Pair with the [Display module](#28-display-module): fetch → `getString` → `displayPrint` shows live data with no host.

**Caveats**
- The firmware's HTTP/JSON parse buffer is **4 KB**; larger bodies are truncated. Fetch the smallest endpoint you can.
- Every literal path/string in a JSON op adds bytes to the task — a JSON-heavy task can approach the budget ([§12](#12-tasks--upload--manage)); the 4096-byte limit (fw 2.19+) exists largely for these.
- Check the status register (`statusInto:`) before trusting the body — a failed fetch leaves stale/empty data.

---

## 20. Strings

Device-side strings live in numbered **slots**. Build them from a literal or a JSON field, inspect,
and print them.

```swift
let s = board.string.createString("hello", into: TaskStringSlot(0)) // literal into slot 0
let r = board.string.reserveString(into: TaskStringSlot(1))         // allocate, emit NO bytes

board.string.length(s, into: .reg(0))
board.string.equals(s, "hello", into: .boolReg(1))
board.string.contains(s, "ell", into: .boolReg(2))
board.string.indexOf(s, "lo", into: .reg(3))
board.string.toInt(s, into: .reg(4), found: .boolReg(5))
board.string.free(s)
```

`createString` vs `reserveString` — the crucial distinction:

- **`createString("x")`** writes the literal into the slot **every time the op runs**. In a
  `repeatEvery` task it *re-initialises* the slot each pass.
- **`reserveString()`** allocates the slot and emits **no bytes** — nothing overwrites it. Use it
  when something *else* fills the slot (a JSON `getString`, or an IR raw-text capture that writes
  `"[d0,d1,…]"` into it), so the value survives across passes.

**Tips**
- `json.getString(body, path)` writes straight into a string slot — reserve it, fetch, then `displayPrint` it.
- `toInt`'s `found:` flag distinguishes "parsed 0" from "not a number".

**Caveats**
- Slots are a small fixed pool shared with JSON snapshots. Reuse slots deliberately.
- A `createString` inside a repeating loop that also expects an external writer clobbers that writer each pass — that's exactly when you want `reserveString` ([§25](#25-ir-module) shows the IR raw-text case).

---

## 21. Nested tasks

A task can upload and schedule **another** task, with no host involved:

```swift
try await client.uploadTask(id: 6) { parent in
    parent.addTask(id: 7, repeatEvery: .milliseconds(500)) { child in
        child.digitalWrite(pin: .pin(2), high: true)
        child.delay(.milliseconds(250))
        child.digitalWrite(pin: .pin(2), high: false)
    }
    parent.deleteTask(id: 7)   // …or stop one
}
```

**Tips**
- Use a parent task as an installer: on a button press it spins up a worker, on another it tears it down — a state machine that reconfigures itself offline.

**Caveats**
- The child's compiled bytes are embedded in the parent, and its ~8/7-encoded upload also counts toward the parent's **4096-byte** budget. Keep children small.

---

## 22. Telemetry & heap

Push a string from a task to whatever host is connected, and read the board's memory:

```swift
try await client.uploadTask(id: 8, repeatEvery: .seconds(5)) { board in
    board.sendString("still alive")                       // → messages stream, .stringData
    board.heapStats(freeInto: .reg(0), largestInto: .reg(1))
}
```

Live, `sendString` exists too (`try await client.sendString("hi")`), arriving as `.stringData` on
the [messages stream](#2-the-messages-stream).

**Tips**
- `heapStats` into public registers lets you watch for fragmentation/leaks via `queryRegisters()` while a long task churns HTTP/JSON.
- `sendString` is a poor-man's `printf` for a task misbehaving in the field.

**Caveats**
- `sendString` reaches only a *connected* host; with nobody listening it's a no-op (no buffering).

---

## 23. Custom transports

| Transport | When |
|---|---|
| `BonjourTransport()` | Same LAN — discovers `_firmata._tcp` via mDNS. Info.plist: `NSLocalNetworkUsageDescription` + `NSBonjourServices`. |
| `TCPTransport(host:port:)` | Known address — static IP, other subnet, VPN, SSH tunnel. No discovery, no Info.plist keys. |
| `BLETransport()` | No network — Nordic UART Service. Info.plist: `NSBluetoothAlwaysUsageDescription`. |
| `SerialTransport(path:)` | USB cable (macOS). Opening the port resets the board. |

`FirmataTransport` is a two-requirement protocol — implement it to bring your own link:

```swift
public protocol FirmataTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func openStream() -> AsyncThrowingStream<UInt8, Error>
}
```

**Tips**
- Any duplex byte pipe works — a mock, a WebSocket bridge, a pair of pipes for tests. The client only needs `send` + a byte `openStream`.
- `MockTransport` in the test target plays a scripted board (including the provisioning-crypto round-trip) — model your own fake on it.

**Caveats**
- The client frames/de-frames SysEx itself; a transport just moves bytes. Don't buffer or reorder.

---

## 24. Modules — discovery & the generic primitive

Optional hardware subsystems sit behind two generic primitives; each vendored package layers typed
calls on top. **Always check presence first.**

```swift
let mods = try await client.queryModules()                 // [ModuleInfo] — id, name, version
guard mods.contains(where: { $0.name == "ir" }) else { return }

// Raw escape hatch (what the typed calls build on):
try await client.sendToModule(id: 0x01, payload: [0x00, 4]) // configure IR TX on pin 4
```

Task-side, the same primitive is `moduleOp(id:payload:)`. Module packages wrap both. For
request/reply ops (a one-shot read that answers directly, like `sonarRead()`),
`sendToModuleAwaitingReply(id:payload:)` sends and awaits the module's reply event.

| ID | Module | Feeds | Package |
|----|--------|-------|---------|
| `0x01` | `ir` | int register / string / messages | SwiftFirmataIR |
| `0x02` | `sonar` | int register (cm) | SwiftFirmataSonar |
| `0x03` | `dht` | float regs (°C/%RH) + int status | SwiftFirmataDHT |
| `0x04` | `display` | (output) | SwiftFirmataDisplay |

**Tips**
- Each module has a `has…Module()` convenience (`hasIRModule()`, `hasSonarModule()`, …) — use it instead of matching names by hand.
- Modules and tasks meet at **registers**: a module writes a register, a task reads it. That's the whole offline-reactivity story.

**Caveats**
- Modules require firmware 2.16+ (IR is older, 2.9+). A module absent from `queryModules()` isn't in that firmware build.

---

## 25. IR module

`import SwiftFirmataIR`. Infrared over the ESP32 RMT peripheral — send and receive NEC, RC6, and
Coolix (Midea-family AC), plus raw timing replay and two learning tools. Module id `0x01`.

### Transmit (live and task)

```swift
try await client.irConfigureTransmit(pin: .pin(4))       // once
try await client.irSendNEC(0x20DF10EF)                    // 38 kHz
try await client.irSendRC6(0x0C)                          // 36 kHz — e.g. TV power
try await client.irSendCoolix(0xB27BE0)                   // 38 kHz — AC off
try await client.irSendRaw(carrierHz: 38_000, durations: [9000, 4500, /* … */])
```

All sends are **single-frame**. To repeat a key, wrap the send in a task `repeat` ([§16](#16-repeat--once)):

```swift
try await client.uploadTask(id: 1) { board in
    board.irConfigureTransmit(pin: .pin(4))
    board.`repeat`(times: 4, gap: .milliseconds(40)) { $0.irSendNEC(0x20DF10EF) }
}
```

A task can also encode a code from a **register** at runtime — replay something you just received
without the host ever knowing the value:

```swift
board.irSendNEC(fromRegister: .reg(0))     // op 0x05
board.irSendRC6(fromRegister: .reg(0))
board.irSendCoolix(fromRegister: .reg(0))
```

### Receive into a register

Three protocol decoders, all sharing one raw RMT capture underneath:

```swift
try await client.irReceiveNEC(pin: .pin(18), into: 0)     // R0 ← decoded frame; also on messages
try await client.irReceiveRC6(pin: .pin(18), into: 0)     // values include mode+toggle bits
try await client.irReceiveCoolix(pin: .pin(18), into: 0)  // folded 24-bit code

for await m in await client.messages {
    if let code = m.module.ir.code { print(String(code, radix: 16)) }
}
```

Task-side — **arm inside `once { }`** so a repeating task doesn't reset the receiver each pass:

```swift
try await client.uploadTask(id: 2, repeatEvery: .milliseconds(100)) { board in
    board.once { $0.irReceiveNEC(pin: .pin(18), into: .reg(0)) }
    board.ifTrue(.reg(0), .equal, .number(0x20DF10EF),
                 then: { $0.digitalWrite(pin: .pin(2), high: true) })
}
```

### Learning an unknown remote

Two tools when you don't know the protocol:

```swift
// (a) Sniff to the host as raw timings (firmware 2.17+):
try await client.irStartRawCapture(pin: .pin(18))
for await m in await client.messages {
    if let frame = m.module.ir.rawFrame { print(frame.durations) }   // learn, then replay via irSendRaw
}
try await client.irStopRawCapture()

// (b) Capture raw timings as TEXT into a device string (firmware 2.18+) — print it on an OLED:
try await client.uploadTask(id: 3, repeatEvery: .milliseconds(200)) { board in
    let s = board.string.reserveString(into: TaskStringSlot(0))     // reserve, don't createString
    board.once { $0.irReceiveRawText(pin: .pin(18), into: s) }       // writes "[d0,d1,…]"
    board.displayPrint(s, line: 0)                                   // read it right off the glass
}
```

**Tips**
- RC6 keys alternate a toggle bit between presses, so the same key reads e.g. `0x0000C` then `0x1000C`. Compare against both `code` and `code | 0x10000`.
- Coolix frames are doubled on the wire (as real remotes send them); the decoder folds the byte+complement pairs back to the 24-bit code.
- To *learn* a protocol, `irReceiveRawText` into a **reserved** string and print it — the durations fingerprint the protocol (header + lead bits).

**Caveats**
- IR transmit needs a proper emitter driven at **5 V**; at 3.3 V the LED is underpowered and the TV/AC won't see it. Receive at 3.3 V is fine.
- `irReceiveRawText` uses `reserveString`, **not** `createString` — a `createString` in a repeating task re-blanks the slot every pass and you'll never see a capture ([§20](#20-strings)).
- Raw-text capture is capped at ~90 durations (header + lead bits of long AC frames) — enough to identify a protocol, not to bit-perfectly clone a 100+ symbol AC state frame.
- Arm the receiver in `once { }`. Re-arming every pass leaves it "reads only the first frame".

---

## 26. Sonar module

`import SwiftFirmataSonar`. HC-SR04 / US-100 ultrasonic distance over a trigger/echo pin pair, into
an integer register in **centimetres** (`-1` = no echo). Module id `0x02`. That register is what
makes it task-native — a task reads it and reacts with nobody connected.

```swift
try await client.sonarConfigure(trigger: .pin(5), echo: .pin(18))

let cm = try await client.sonarRead()                      // one-shot: pings, returns cm directly
                                                           // (-1 = no echo); no register touched

try await client.sonarPing(into: 0)                        // one ping → R0 = cm (register form)
try await client.sonarAutoPing(into: 0, every: .milliseconds(200)) // firmware pings itself
print(try await client.queryRegisters().ints[0])           // read live
try await client.sonarAutoPing(into: 0, every: .zero)      // stop
```

A presence detector that runs offline:

```swift
try await client.uploadTask(id: 1, repeatEvery: .milliseconds(200)) { board in
    board.once { $0.sonarAutoPing(into: .reg(0), every: .milliseconds(150)) }
    board.ifTrue(.reg(0), .lessThan, .number(20),
                 then:   { $0.digitalWrite(pin: .pin(2), high: true) },
                 elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })
}
```

**Tips**
- `sonarAutoPing` offloads the timing to the firmware — set it once (in `once { }`) and just read the register.
- `sonarPing(into:)` returns the register as a `TaskNumberRegister`, so you can chain it into `ifTrue`/arithmetic in the same task.

**Caveats**
- Distance is written to the **public bank** (R0–R15). `-1` means no echo — treat it distinctly from a real distance.
- Auto-ping period is capped at ~16 s.
- HC-SR04 echo is a 5 V pin; level-shift or divide it to 3.3 V before the ESP32 echo GPIO.

---

## 27. DHT module

`import SwiftFirmataDHT`. DHT11/DHT22 temperature + humidity on one data pin, into **float
registers** (°C / %RH) plus an integer ok-flag. The firmware auto-reads on the sensor's ~2 s cadence
once configured. Module id `0x03`.

```swift
try await client.dhtConfigure(pin: .pin(4), type: .dht22,
                             temperatureInto: 0,     // F0 = °C
                             humidityInto: 1,        // F1 = %RH
                             statusInto: 0)          // R0 = 1 ok / 0 failed read
let t = try await client.dhtReadTemperature()          // one-shot: reads, returns °C directly
let h = try await client.dhtReadHumidity()             // %RH (throws if the sensor read fails — retry)

try await client.dhtReadNow()                          // or: nudge the auto-read → registers
let snap = try await client.queryRegisters()
print(snap.floats[0], snap.floats[1], snap.ints[0])
```

An offline thermostat:

```swift
try await client.uploadTask(id: 1, repeatEvery: .seconds(2)) { board in
    board.once {
        $0.dhtConfigure(pin: .pin(4), type: .dht22,
                        temperatureInto: .freg(0), humidityInto: .freg(1), statusInto: .reg(0))
    }
    board.ifTrue(.freg(0), .greaterThan, .float(28),
                 then:   { $0.digitalWrite(pin: .pin(12), high: true) },   // fan on
                 elseDo: { $0.digitalWrite(pin: .pin(12), high: false) })
}
```

**Tips**
- Gate on the status register — a failed read keeps the *previous* float values, so `R[status] == 0` means "stale".
- DHT11 vs DHT22 differ in encoding; pass the right `DHTSensorType` or values are wrong.

**Caveats**
- Floats land in the **public** float bank (F0–F7), status in the **public** int bank (R0–R15).
- The sensor physically allows one read per ~2 s; `dhtReadNow` forces the *next* firmware pass, it can't beat the sensor's floor.

---

## 28. Display module

`import SwiftFirmataDisplay`. SSD1306 / SH1106 128×64 OLED over I²C. The op set is built for tasks:
print a device **string** (from `json.getString` / `createString`) or a **register**, so an offline
task can fetch → extract → display. Every print pads to the end of the line, so a shorter new value
never leaves ghosts. Module id `0x04`.

```swift
try await client.displayConfigure(address: 0x3C, kind: .ssd1306)  // once; .sh1106 if edges are off
try await client.displayClear()
try await client.displayPrint("Hello", line: 0)
try await client.displayPrint("temp:", line: 1)
try await client.displayPrint(register: 0, line: 1, col: 6)       // R0 as decimal
try await client.displayPrint(floatRegister: 0, line: 2)          // F0 with 2 decimals
```

Fonts: the default **5×7** gives 8 lines × **21 columns**; the compact **4×6** (`smallFont: true`)
gives 8 lines × **25 columns** — more text per line:

```swift
try await client.displayConfigure(kind: .ssd1306, smallFont: true)
```

The task payoff — fetch a value and show it, no host:

```swift
try await client.uploadTask(id: 1, repeatEvery: .minutes(5)) { board in
    board.once { $0.displayConfigure(kind: .ssd1306) }
    let res = board.httpGet("http://api.example.com/weather", statusInto: .reg(0))
    let city = board.json.getString(res.body, "name")            // TaskString
    board.json.getFloat(res.body, "main.temp", into: .freg(0))
    board.displayPrint(city, line: 0)
    board.displayPrint(.freg(0), line: 1)                        // F0 with 2 decimals
    board.json.free(res.body)
}
```

**Tips**
- **`.sh1106`** if the left edge is cut off / the right shows noise — those very common "128×64" boards have 132-column RAM centred at cols 2–129; the kind adds the column offset.
- Each print is independent and self-padding, so you can refresh one line without clearing the panel.
- `displayPrint(_ string: TaskString)` is the bridge from JSON / IR-text capture to the glass.

**Caveats**
- Text is 7-bit ASCII; non-ASCII renders as `?`. A line clamps to 21 chars (5×7 / 25 with the small font).
- `line` is 0–7, `col` is 0-based. Off-panel coordinates are masked, not errored.
- String slots referenced by `displayPrint(_:)` come from the device string pool (slots 0–1 are the JSON snapshot slots; strings start internally at index 2 — the package maps a `TaskString` to the right device slot for you).

---

## 29. Mic module

`import SwiftFirmataMic`. Sound level from an analog microphone (module id `0x05`, firmware
**2.22+**). The host's sampling stream is ~10 Hz — useless for audio — so the firmware
burst-samples the ADC on-device each window (~16 ms at a few kHz), computes the DC-removed RMS,
converts to decibels, and writes **dB → `F[db]`** and **raw RMS counts → `R[rms]`** every window
(default 250 ms, minimum 50).

```swift
import SwiftFirmataClient
import SwiftFirmataMic

guard try await client.hasMicModule() else { return }
try await client.micConfigure(pin: .pin(32), decibelsInto: 2, rmsInto: 3)

let db = try await client.micReadDecibels()        // one-shot: measure now, reply directly

let regs = try await client.queryRegisters()       // …or poll the auto-refreshed registers
print(regs.floats[2], "dB", regs.ints[3], "rms")
```

dB is **relative full-scale** (full-scale sine ≈ 0 dB; silence on an unamplified electret ≈ −45)
until a one-point calibration — hold any SPL meter (phone app) next to the mic once:

```swift
let offset = referenceDb - (try await client.micReadDecibels())
try await client.micSetCalibration(offset: offset)  // firmware adds it to every reading
```

**Digital I²S MEMS mic (INMP441 / SPH0645)** — firmware **2.23+**. Same module, same dB/RMS
outputs, but read over I²S instead of the ADC: no analog noise floor and true audio-rate sampling
(16 kHz on-device). Wire SCK→`bclk`, WS→`ws`, SD→`data`, **L/R→GND** (left slot), VDD→**3V3**
(keep ≤ 3.6 V — over-volting kills the mic). Solder the header — a jumper poked into an unsoldered
pad reads as silence:

```swift
try await client.micConfigureI2S(bclk: .pin(14), ws: .pin(27), data: .pin(32),
                                 decibelsInto: 2, rmsInto: 3,
                                 sampleRate: 16_000)   // 8k–48k; firmware 2.24+ (else fixed 16 kHz)
let db = try await client.micReadDecibels()

// Diagnostic when a fresh INMP441 reads silence — is SD carrying anything at all?
let peak = try await client.micI2SPeakRaw()   // 0 ⇒ dead/unpowered mic or a wiring/solder fault
```

One-shot reads, `micSetCalibration`, and the loudness task below are identical — only the
`configure` call differs. The I²S full-scale reference is 2²³ (24-bit MEMS) vs the ADC's 2048/√2,
so re-calibrate after switching mics. `sampleRate` is the on-device audio clock — 16 kHz is ample
for a dB meter; raise it only for higher-frequency capture.

**Dominant frequency (FFT)** — firmware **2.24+**, I²S only. The firmware Hann-windows + FFTs each
window and writes the peak frequency in **Hz → `F[hz]`** (0 = no tone stands out). Resolution is
`sampleRate / 512` (≈31 Hz at 16 kHz), refined by parabolic interpolation. Great for whistle / pitch
/ single-tone triggers:

```swift
try await client.micConfigureI2S(bclk: .pin(14), ws: .pin(27), data: .pin(32), decibelsInto: 2, rmsInto: 3)
try await client.micEnableFrequency(into: 3)          // dominant Hz → F3 each window
let regs = try await client.queryRegisters()
print(regs.floats[3], "Hz")                            // 0.0 ⇒ silence / broadband noise
// …later: try await client.micDisableFrequency()

// Fire when a ~1 kHz whistle is heard. Configure the I²S mic + frequency live first (the
// recorder configures analog mics inside a task; I²S is configured host-side), then the task
// just reacts to F3 with no host attached:
try await client.micConfigureI2S(bclk: .pin(14), ws: .pin(27), data: .pin(32), decibelsInto: 2, rmsInto: 3)
try await client.micEnableFrequency(into: 3)
try await client.uploadTask(id: 4, repeatEvery: .milliseconds(300)) { board in
    board.ifTrue(.freg(3), .greaterThan, .float(950),
                 then: { $0.digitalWrite(.pin(2), high: true) })
}
```

The task payoff — react to loudness with no host attached:

```swift
try await client.uploadTask(id: 3, repeatEvery: .milliseconds(500)) { board in
    board.once { $0.micConfigure(pin: .pin(32), decibelsInto: .freg(2), rmsInto: .reg(3)) }
    board.ifTrue(.freg(2), .greaterThan, .float(60),
                 then: { $0.displayPrint("LOUD", line: 0) })
}
```

**Tips**
- Any **ADC1** pin (GPIO 32–39 on a classic ESP32); ADC2 fights Wi-Fi.
- An unamplified electret barely clears the ESP32's ADC noise floor — great for clap/loud
  detection; for a real level meter use an amplified mic (MAX9814), same module unchanged.
- Comparator-output "sound sensor" boards read **binary** here (~floor or ~80+, nothing between):
  a rail-to-rail square wave at 1 % duty already has a huge RMS. Perfect as a loud/quiet trigger —
  the board's pot is the acoustic threshold.

**Caveats**
- A window's burst blocks the firmware loop ~16 ms — same class as a sonar ping; harmless at
  tick cadence, but don't ask for a 50 ms window *and* expect µs-tight servo sweeps in a task.
- The calibration offset survives SYSTEM_RESET but not a power cycle — store it host-side and
  re-send after `micConfigure`.
- `micReadDecibels()` needs a prior `micConfigure` (throws `invalidData` otherwise).

---

## 30. Global caveats & gotchas

- **Everything is RAM.** Registers and tasks survive disconnects but **not reboot**; re-upload on reconnect if you need them to persist. Wi-Fi credentials are the exception (stored in flash).
- **One master, latest wins.** A second client evicts the first (`EVICTED`, stream ends). Don't run two clients against one board expecting both to work.
- **Gate on version.** `queryFirmware()` + `queryModules()` before anything past the 2.15 core. Floors: 2.16 modules, 2.17 sniff/`once`, 2.18 IR raw-text, **2.19 the 4096-byte task budget**.
- **Task budget.** 4096 bytes/task on 2.19+ (512 before). Big offenders: long literal strings, many JSON paths, embedded child tasks. Overflowing uploads throw.
- **The recorder is synchronous and write-only.** It can't return a value to your Swift code — results go to registers; read them with `queryRegisters()` or show them on a display.
- **Public vs internal registers.** You address R0–15 / F0–7. Op results auto-allocate R16–31 / F8–15 so they never trample your public state.
- **5 V peripherals.** IR emitters and HC-SR04 echo want 5 V logic; drive/level-shift accordingly. The ESP32 GPIOs are 3.3 V.
- **Arm-once.** Any module receiver/auto-loop armed inside a `repeatEvery` task belongs in `once { }`. Re-arming every pass is the classic "works for the first read then stops".

---

## 31. Type reference

**Live values**
- `FirmataPin` — `.pin(n)`; `FirmataChannel` — `.channel(n)`.
- `PinMode` — the modes this firmware implements: `.input`/`.inputPullup`/`.inputPulldown`/`.output`/`.analog`/`.pwm`/`.servo`/`.i2c`/`.touch`/`.dac`/`.tone`. Mode-gated writes: `toneWrite(pin:hz:)` / `toneWrite(pin:hz:for:)`, `dacWrite(pin:value:)`, `touchRead(pin:)`.
- `HTTPResponse` — `.status: Int`, `.body: String`. `WiFiStatus`, `RegisterSnapshot` (`.ints`, `.floats`), `ModuleInfo` (`.id`, `.name`, version), `PinState`, `I2CReply`, `[[PinCapability]]`.
- `FirmataMessage` — `.digital` `.analog` `.stringData` `.moduleEvent` `.i2cReply` `.registers` `.modules` … (see [§2](#2-the-messages-stream)).

**Task operands** (all `TaskOperand`)
- Integer: `TaskNumberLiteral` (`.number(_:)`), `TaskNumberRegister` (`.reg(0…15)`).
- Float: `TaskFloatLiteral` (`.float(_:)`), `TaskFloatRegister` (`.freg(0…7)`).
- Boolean: `TaskBoolLiteral` (`.bool(_:)`), `TaskBoolRegister` (`.boolReg(0…15)`).
- Protocol facets: `TaskNumber`, `TaskFloat`, `TaskBool` — what an op accepts/returns.

**Task handles & slots**
- `TaskPin` (`.pin(n)`), `TaskChannel` (`.channel(n)`).
- `TaskString` (+ `TaskStringSlot`), `TaskResponseBody`, `TaskHTTPResponse` (`.status: TaskNumberRegister`, `.body: TaskResponseBody`), `TaskJSONSlot`, `TaskJSONType`/`TaskJSONValueType`.
- `TaskComparison` — `.equal` `.notEqual` `.lessThan` `.greaterThan` `.lessThanOrEqual` `.greaterThanOrEqual`.

**Recorder & scheduler**
- `FirmataTaskRecorder` — the verb surface inside `uploadTask { board in … }`; `.json` (`TaskJSONOps`), `.string` (`TaskStringOps`).
- `SchedulerTask` — a task read back via `queryTask(id:)` (`.id`, `.timeMs`, `.length`, `.position`, `.data`).

**Modules** (each its own package)
- IR `0x01` (SwiftFirmataIR): `irConfigureTransmit`, `irSendNEC/RC6/Coolix/Raw`, `irSend*(fromRegister:)`, `irReceiveNEC/RC6/Coolix`, `irReceiveRawText`, `irStartRawCapture`/`irStopRawCapture`; `message.module.ir.code`/`.rawFrame`.
- Sonar `0x02` (SwiftFirmataSonar): `sonarConfigure`, `sonarRead` (one-shot → cm), `sonarPing`, `sonarAutoPing`.
- DHT `0x03` (SwiftFirmataDHT): `dhtConfigure`, `dhtReadTemperature`/`dhtReadHumidity` (one-shot), `dhtReadNow`; `DHTSensorType`.
- Display `0x04` (SwiftFirmataDisplay): `displayConfigure` (`DisplayKind`, `smallFont`), `displayClear`, `displayPrint` (text / register / float / `TaskString`).
