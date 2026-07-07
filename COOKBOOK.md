# Cookbook

One copy-paste recipe per feature. `client` is a connected `FirmataClient`; inside
`uploadTask { board in … }` the `board` is a `FirmataTaskRecorder` — its calls are
recorded, not sent, so they're synchronous (no `await`).

1. [Connecting](#1-connecting)
2. [Messages](#2-messages)
3. [Digital & analog I/O](#3-digital--analog-io)
4. [Input streams](#4-input-streams)
5. [Queries](#5-queries)
6. [I²C](#6-i²c)
7. [Internet requests (live)](#7-internet-requests-live)
8. [Wi-Fi provisioning](#8-wi-fi-provisioning)
9. [Tasks — upload & manage](#9-tasks--upload--manage)
10. [Recorder — the basic verbs](#10-recorder--the-basic-verbs)
11. [Registers & operands](#11-registers--operands)
12. [Branches](#12-branches)
13. [Loops](#13-loops)
14. [Arithmetic](#14-arithmetic)
15. [On-device reads](#15-on-device-reads)
16. [Internet & JSON in a task](#16-internet--json-in-a-task)
17. [Strings](#17-strings)
18. [Nested tasks](#18-nested-tasks)
19. [Telemetry](#19-telemetry)
20. [Custom transports](#20-custom-transports)
21. [Type reference](#21-type-reference)

## 1. Connecting

```swift
// Same LAN, zero config (Info.plist: NSLocalNetworkUsageDescription + NSBonjourServices):
let client = FirmataClient(transport: BonjourTransport())

// Known address — VPN, tunnel, static IP; no discovery, no Info.plist keys:
let client = FirmataClient(transport: TCPTransport(host: "192.168.1.87"))   // port 3030

// BLE (Info.plist: NSBluetoothAlwaysUsageDescription):
let client = FirmataClient(transport: BLETransport())

// USB serial (macOS). Opening the port resets the board — give it a moment to boot:
let client = FirmataClient(transport: SerialTransport(path: "/dev/cu.usbserial-0001"))

await client.connect()
let fw = try await client.queryFirmware()
```

The board serves **one master at a time** — the newest connection wins, the old one
is evicted. Over serial there's no disconnect event: the port speaks Firmata from
your first byte until another transport claims the board or it reboots.

## 2. Messages

```swift
for await message in client.messages {
    switch message {
    case .digitalPort(let port, let mask): print("port \(port): \(mask)")
    case .analog(let ch, let value):       print("A\(ch) = \(value)")
    case .stringData(let s):               print("board says: \(s)")
    default: break
    }
}
// The loop ends when the connection does (eviction, transport error, disconnect()).
```

## 3. Digital & analog I/O

```swift
try await client.setPinMode(.pin(2), mode: .output)        // .input .inputPullup .analog .pwm .servo
try await client.digitalWrite(pin: .pin(2), high: true)
try await client.writeDigitalPort(0, pinMask: 0b0000_0100) // 8 pins at once

try await client.setPinMode(.pin(4), mode: .pwm)
try await client.analogWrite(channel: .channel(4), value: 128)     // 0–255 duty
try await client.extendedAnalogWrite(pin: .pin(25), value: 1500)   // pins ≥ 16 / wide values

let pressed = try await client.digitalRead(pin: .pin(7))           // one-shot
let light   = try await client.analogRead(channel: .channel(0))    // A0, 0–4095 on ESP32
```

### Servo

```swift
try await client.setPinMode(.pin(13), mode: .servo)                // default 544–2400 µs
try await client.servoWrite(pin: .pin(13), value: 90)              // 0–180 = degrees
try await client.configureServo(pin: .pin(13), minPulseMicros: 1000, maxPulseMicros: 2000)
try await client.servoWrite(pin: .pin(13), value: 1500)            // ≥ 544 = raw pulse µs
```

## 4. Input streams

```swift
try await client.setSamplingInterval(.milliseconds(100))
try await client.reportAnalogChannel(.channel(0), enable: true)    // -> .analog messages
try await client.reportDigitalPort(0, enable: true)                // -> .digitalPort on change
```

## 5. Queries

```swift
let ver  = try await client.queryProtocolVersion()   // Firmata 2.x
let fw   = try await client.queryFirmware()           // name + version
let caps = try await client.queryCapabilities()       // [[PinCapability]] per pin
let map  = try await client.queryAnalogMapping()      // channel -> pin
let st   = try await client.queryPinState(pin: .pin(2))
```

## 6. I²C

```swift
try await client.configureI2C()                       // begin the bus once

try await client.i2cWrite(address: 0x3C, data: [0x00, 0xAE])
let reply = try await client.i2cReadOnce(address: 0x48, registerAddress: 0x00, count: 2)
// registerAddress is the peripheral's register pointer, written first.

try await client.i2cStartReading(address: 0x48, registerAddress: 0x00, count: 2)
// -> .i2cReply messages at the sampling interval …
try await client.i2cStopReading(address: 0x48)
```

## 7. Internet requests (live)

The **board's** Wi-Fi performs the request (HTTPS validated on-device); you get the
status plus up to ~4 KB of body back.

```swift
let resp = try await client.httpGet("https://api.example.com/state")
if resp.isSuccess {
    let obj   = try resp.json()                 // Foundation object graph
    let typed = try resp.decode(MyModel.self)   // or Codable
}
let posted = try await client.httpPost("https://api.example.com/ingest", body: #"{"v":1}"#)
```

## 8. Wi-Fi provisioning

Hand the board its credentials over **any** transport — an ephemeral X25519
handshake derives an AES-256-GCM key, so the password never travels in the clear.
Creds persist in NVS and are saved only after a successful join; a wrong password
rolls back to the previous network.

```swift
let status = try await client.provisionWiFi(ssid: "MyNetwork", password: "…")
print(status.connected, status.ip ?? "-")

let now = try await client.queryWiFiStatus()
try await client.forgetWiFi()                   // fall back to compile-time creds
```

BLE and serial survive the network change; a TCP/Bonjour connection drops with it,
so provision over BLE/serial when actually switching networks.

## 9. Tasks — upload & manage

```swift
try await client.uploadTask(id: 1,
                            startDelay: .seconds(2),          // optional
                            repeatEvery: .milliseconds(500))  // omit for one-shot
{ board in
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(250))
    board.digitalWrite(pin: .pin(2), high: false)
}
// uploadTask replaces any task with the same id and round-trips a confirmation,
// so it's safe to disconnect() right after it returns.

let ids  = try await client.queryAllTasks()
let info = try await client.queryTask(id: 1)    // position / length / next run
try await client.deleteTask(id: 1)
try await client.resetTasks()                   // delete all
```

Limits: 8 task slots, 512 recorded bytes per task, ids 0–127. One-shot tasks remove
themselves; a trailing `delay` makes a task loop (what `repeatEvery` records). Tasks
live in RAM — reboot clears them.

## 10. Recorder — the basic verbs

```swift
try await client.uploadTask(id: 1) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.digitalWrite(pin: .pin(2), high: true)
    board.writeDigitalPort(0, pinMask: 0xFF)
    board.analogWrite(channel: .channel(4), value: 200)
    board.extendedAnalogWrite(pin: .pin(25), value: 1500)
    board.delay(.milliseconds(1000))            // the board waits here

    board.configureI2C()                        // I²C from a task (OLED, sensors…)
    board.i2cWrite(address: 0x3C, data: [0x00, 0xAE])
}
```

## 11. Registers & operands

The device has 32 global `Int32` registers (bools are 0/1 in the same bank) and 16
floats. **R0–R15 / F0–F7 are public** — yours to read, write, and pin. **R16–R31 /
F8–F15 are internal**: value-producing ops auto-allocate their results there, so
temporaries never clobber your public registers. Every value-producing op returns a
typed operand you can feed to later ops; destinations auto-allocate unless pinned
with `into:`.

```swift
try await client.uploadTask(id: 1, repeatEvery: .seconds(5)) { board in
    let light = board.analogRead(channel: .channel(0))       // TaskNumber (auto reg)
    board.analogRead(into: .reg(3), channel: .channel(0))    // pinned: R3

    board.setRegister(.reg(4), to: .number(1500))            // R4 = literal
    board.setFloatRegister(.freg(0), to: .float(21.5))       // F0 = literal

    // .reg(n) is also an operand — read state the host or another task wrote:
    board.ifTrue(.reg(4), .greaterThan, light) { $0.digitalWrite(pin: .pin(2), high: true) }
}
```

The host reads and writes the same public cells live:

```swift
try await client.setRegister(4, to: 1500)                 // task ifTrue sees it next pass
try await client.setFloatRegister(0, to: 21.5)
let snap = try await client.queryRegisters()              // RegisterSnapshot: R0–R15 + F0–F7
print(snap.ints[4], snap.floats[0])
```

Pin a public register when the value must be visible to the host or another task.
Operand literals: `.number(_)`, `.float(_)`, `.bool(_)`; registers: `.reg(_)`,
`.freg(_)`, `.boolReg(_)`.

## 12. Branches

```swift
board.ifTrue(light, .lessThan, .number(300), then: {
    $0.digitalWrite(pin: .pin(2), high: true)      // $0 is the branch recorder
}, elseDo: {
    $0.digitalWrite(pin: .pin(2), high: false)
})

let pressed = board.digitalRead(pin: .pin(7))      // TaskBool
board.ifTrue(pressed) { $0.sendString("pressed") } // truthy shorthand (≠ 0)

let ok = board.compare(light, .greaterOrEqual, .number(100))   // -> TaskBool, reusable
```

Comparisons: `.equal .notEqual .lessThan .greaterThan .lessOrEqual .greaterOrEqual`.
Mixed int/float comparisons promote to float. Branches nest arbitrarily.

## 13. Loops

`loop(_:gap:)` runs a block exactly N times on the device, pausing `gap` between
iterations (never after the last) — a native counted loop, not host-side unrolling,
so the task stays tiny regardless of N.

```swift
board.loop(5, gap: .milliseconds(200)) {
    $0.digitalWrite(pin: .pin(2), high: true)
    $0.delay(.milliseconds(50))
    $0.digitalWrite(pin: .pin(2), high: false)
}
```

Loops nest up to 4 deep; `count 0` skips the body. This is the reliable way to do
something *exactly* N times — e.g. wrap a single IR send to press a remote key N
times (see [SwiftFirmataIR](https://github.com/doraorak/SwiftFirmataIR)).

## 14. Arithmetic

```swift
let sum = board.add(light, .number(100))           // subtract / multiply / divide / modulo
let pct = board.divide(sum, .number(41))           // integer; ÷0 and %0 yield 0
let f   = board.multiplyFloat(.freg(0), .float(1.8))   // + addFloat/subtractFloat/divideFloat
```

## 15. On-device reads

```swift
let btn  = board.digitalRead(pin: .pin(7))                 // TaskBool
let a0   = board.analogRead(channel: .channel(0))          // TaskNumber
let temp = board.i2cRead(address: 0x48, registerAddress: 0x00, count: 2)
// i2cRead writes the register pointer, reads 1–4 bytes, packs them big-endian.
```

## 16. Internet & JSON in a task

```swift
try await client.uploadTask(id: 2, repeatEvery: .seconds(60)) { board in
    let resp = board.httpGet("https://api.example.com/state")   // TaskHTTPResponse

    board.ifTrue(resp.status, .equal, .number(200), then: {
        let level = $0.json.getNumber(resp.body, "sensor.level")   // Int32, truncated
        let volts = $0.json.getFloat(resp.body, "sensor.volts")    // TaskFloat
        let n     = $0.json.getSize(resp.body, "readings")         // array/object size
        let has   = $0.json.bodyContains(resp.body, "alarm")       // TaskBool

        let kind = $0.json.getType(resp.body, "result")
        $0.ifTrue(kind, is: .string) { $0.sendString("string result") }

        $0.ifTrue(level, .greaterThan, .number(80)) { $0.digitalWrite(pin: .pin(2), high: true) }
    })
}
```

Paths use `a.b[0]` syntax. `getNumber(scaledBy: k)` multiplies by 10^k before
truncation; `found:` optionally stores a 1/0 parse flag in a register.

A body is overwritten by the **next** request. To keep one, snapshot it:

```swift
let resp = board.httpGet("https://…")
board.json.snapshot(resp.body)                     // survives later requests
// … more requests …
board.json.free(resp.body)                         // release the slot
```

The snapshot pool has 12 slots: 2 for JSON bodies, 10 for strings. Slots
auto-allocate and wrap; pin one with `into: TaskJSONSlot(0…1)` /
`TaskStringSlot(0…9)` to share it across tasks or protect it from wraparound.

## 17. Strings

`json.getString` captures a JSON string's (unquoted) content into a string slot;
`string.createString` loads a literal. Both return a `TaskString` handle:

```swift
let name = board.json.getString(resp.body, "device.name")
let tag  = board.string.createString("kitchen", into: TaskStringSlot(7))   // pinned slot

let len  = board.string.length(name)                        // TaskNumber
let eq   = board.string.equals(name, "esp32")               // TaskBool
let has  = board.string.contains(name, "32")
let at   = board.string.indexOf(name, "32")                 // -1 if absent
let num  = board.string.toInt(name)                         // clamped Int32
board.string.free(tag)                                      // release the slot
```

## 18. Nested tasks

A task can upload and schedule **another task** — no host involved. Each execution
replaces the child (delete → create → fill → schedule), so a repeating parent
restarts its child every period.

```swift
try await client.uploadTask(id: 1, repeatEvery: .seconds(60)) { board in
    let temp = board.i2cRead(address: 0x48, registerAddress: 0x00, count: 2)
    board.ifTrue(temp, .greaterThan, .number(2800), then: {
        $0.addTask(id: 2, repeatEvery: .milliseconds(250)) { alarm in
            alarm.digitalWrite(pin: .pin(2), high: true)
            alarm.delay(.milliseconds(125))
            alarm.digitalWrite(pin: .pin(2), high: false)
        }
    }, elseDo: {
        $0.deleteTask(id: 2)                       // cooled down — stop the alarm
    })
}
```

Registers/slots are global across tasks (pin registers to pass values in); the child
counts against the parent's 512-byte budget; never reuse the enclosing task's own id.

## 19. Telemetry

```swift
board.sendString("threshold crossed")              // -> .stringData on client.messages
let (free, largest) = board.heapStats()            // TaskNumbers: heap bytes
```

## 20. Custom transports

`FirmataTransport` has two requirements — anything that moves bytes qualifies:

```swift
final class MyTransport: FirmataTransport {
    func send(_ bytes: [UInt8]) async throws { /* write to your link */ }
    func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            // yield incoming bytes; finish() / finish(throwing:) when the link dies
        }
    }
}
```

The four shipped transports are ordinary conformances — read their sources as templates.

## 21. Type reference

| Type | What it is |
|---|---|
| `TaskOperand` | Anything an op accepts: literal or register |
| `TaskNumber` / `TaskFloat` / `TaskBool` | Typed operand protocols returned by ops |
| `TaskNumberRegister` `.reg(0–31)` | An `Int32` register (public 0–15); also `TaskBoolRegister` `.boolReg`, same bank |
| `TaskFloatRegister` `.freg(0–15)` | A float register (public 0–7) |
| `TaskNumberLiteral` `.number(_)` etc. | Compile-time constants |
| `TaskPin` `.pin(0–127)` / `TaskChannel` `.channel(0–15)` | Typed pin/channel identities (recorder) |
| `FirmataPin` / `FirmataChannel` | The same, for the live client |
| `TaskHTTPResponse` | `.status` (TaskNumber) + `.body` (TaskResponseBody) |
| `TaskString` | Handle to a captured string slot |
| `TaskJSONSlot(0–1)` / `TaskStringSlot(0–9)` | Explicit snapshot-pool slots |
| `TaskJSONType` + `TaskJSONValueType` | JSON kind register + `.missing/.object/.array/.string/.number/.bool/.null` |
| `SchedulerTask` | `queryTask` result: id, time, length, position, bytes |
| `WiFiStatus` / `HTTPResponse` / `PinState` / `I2CReply` | Live-call results |
