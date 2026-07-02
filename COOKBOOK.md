# SwiftFirmataClient — Per-Feature Cookbook

Idiomatic, heavily-commented snippets for **every** feature of the client library
(Firmata protocol v2.8.0 + this project's non-standard logic/internet extension).

`FirmataClient` is an **actor** — every call is `await`, and it's safe to use from
any task. Add `import SwiftFirmataClient` at the top of each file.

---

## Table of contents

1. [Connecting — transports, connect, disconnect](#1-connecting)
2. [The `messages` stream + disconnect reasons](#2-the-messages-stream--disconnect-reasons)
3. [Digital I/O](#3-digital-io)
4. [Analog / PWM I/O](#4-analog--pwm-io)
5. [System: reset, sampling, strings](#5-system)
6. [Queries: version, firmware, capabilities, mapping, pin state](#6-queries)
7. [I2C](#7-i2c)
8. [Live internet requests (over the board's Wi-Fi)](#8-live-internet-requests)
9. [Scheduler tasks — high-level `uploadTask`](#9-scheduler-tasks--high-level-uploadtask)
10. [Scheduler tasks — low-level building blocks](#10-scheduler-tasks--low-level-building-blocks)
11. [Recorder: the basic task verbs](#11-recorder-the-basic-task-verbs)
12. [On-device logic: registers + reads](#12-on-device-logic-registers--reads)
13. [The operand model (typed)](#13-the-operand-model-typed)
14. [`ifTrue` and `compare` (branching)](#14-iftrue-and-compare)
15. [Arithmetic — integer and float](#15-arithmetic--integer-and-float)
16. [Heap stats](#16-heap-stats)
17. [Internet inside a task → `TaskHTTPResponse`](#17-internet-inside-a-task)
18. [JSON inspection on the device (`board.json`)](#18-json-inspection-on-the-device)
19. [Snapshots & staleness (`snapshot`, `isValid`, `free`)](#19-snapshots--staleness)
20. [Strings — `board.string`](#20-strings--boardstring)
21. [Custom transport](#21-custom-transport)
22. [Type reference](#22-type-reference)
23. [Wi-Fi provisioning (encrypted, over BLE)](#23-wi-fi-provisioning-encrypted-over-ble)

---

## 1. Connecting

The client talks to the board through a **transport**. Three ways to get one:

```swift
import SwiftFirmataClient

// (a) Wi-Fi / Bonjour — discovers the first `_firmata._tcp` service on the LAN.
let transport = BonjourTransport()

// …or pin a specific board by its mDNS instance name (the firmware's MDNS_HOST):
let transport = BonjourTransport(named: "esp32-firmata",
                                 connectTimeout: 15)   // seconds before giving up

// (b) Bluetooth LE — Nordic UART Service. `peripheralName: nil` takes the first match.
let transport = BLETransport(peripheralName: "esp32-firmata")

// (c) Anything you implement — see §21 (Custom transport).
```

```swift
// One client owns ONE transport for its whole life. Never point two live clients
// at the same board: the firmware enforces a single master and evicts the loser.
let client = FirmataClient(transport: transport)

// Start the background receive loop. Call exactly once, after creating the client.
await client.connect()

// …use the client…

// Stop reading and fail any in-flight queries. The board keeps running uploaded
// tasks after you disconnect (see §9).
await client.disconnect()
```

---

## 2. The `messages` stream + disconnect reasons

Every message the device sends is published on `client.messages` (an `AsyncStream`).
Use it for **push-style** data: analog/digital reports, device strings, async HTTP
replies, etc. (One consumer per stream.)

```swift
// Consume in a background task so it doesn't block. The loop ends when the
// connection closes (disconnect, network drop, or eviction).
let pump = Task {
    for await msg in client.messages {
        switch msg {
        case .analog(let channel, let value):
            print("A\(channel) = \(value)")                 // needs reportAnalogChannel
        case .digital(let port, let pinMask):
            print("port \(port) bits = \(pinMask, radix: 2)")// needs reportDigitalPort
        case .stringData(let s):
            print("device says: \(s)")
        case .httpResponse(let status, let body):
            print("task HTTP \(status): \(body.prefix(80))") // a task's httpGet, while connected
        default:
            break                                            // query replies are handled for you
        }
    }

    // The stream finished — find out WHY (see the enum below).
    if let reason = await client.lastDisconnectReason {
        print("disconnected: \(reason)")
    }
}
```

```swift
// FirmataDisconnectReason tells you who ended it:
//   .localRequest            — you called disconnect()
//   .replacedByAnotherClient — another app/computer took the board (latest-wins)
//   .transportClosed         — network drop / device reset / power loss
//
// Eviction is detected from the firmware's STRING_DATA sentinel and is NOT surfaced
// as an ordinary .stringData message.
```

---

## 3. Digital I/O

```swift
// Always set a pin's mode before using it.
try await client.setPinMode(13, mode: .output)     // see PinMode for the full list
try await client.setPinMode(7,  mode: .inputPullup)

// Drive a single output pin.
try await client.digitalWrite(pin: 13, high: true) // HIGH
try await client.digitalWrite(pin: 13, high: false)// LOW

// Write a whole 8-pin port at once (faster than 8 calls). Only .output pins move.
// port 0 = pins 0–7; bit N of the mask = pin N (1 → HIGH).
try await client.writeDigitalPort(0, pinMask: 0b0010_0000)  // pin 5 HIGH, rest LOW

// Every live pin/channel call also accepts a typed identity for clarity — `.pin(n)`
// (`FirmataPin`) and `.channel(n)` (`FirmataChannel`). The bare-UInt8 forms stay valid:
try await client.setPinMode(.pin(13), mode: .output)
try await client.digitalWrite(pin: .pin(13), high: true)    // same as pin: 13
```

```swift
// One-shot read. Firmata has no synchronous read, so this momentarily enables port
// reporting, waits for the next report, then restores the previous reporting state.
try await client.setPinMode(7, mode: .inputPullup)
let pressed = try await client.digitalRead(pin: 7) == false   // active-low button
//        digitalRead(pin:timeout:) -> Bool ; throws FirmataError.noResponse on timeout
let level = try await client.digitalRead(pin: 7, timeout: .seconds(1))
```

```swift
// Push-style monitoring: ask the device to report a port whenever an input changes.
// Reports arrive as .digital(port:pinMask:) on `client.messages` (see §2).
try await client.reportDigitalPort(0, enable: true)
// …later…
try await client.reportDigitalPort(0, enable: false)
```

---

## 4. Analog / PWM I/O

```swift
// PWM out. For pins 0–15 the "channel" is the pin number. Range depends on the pin's
// PWM resolution from the capability response (e.g. 0–255 for 8-bit).
try await client.setPinMode(3, mode: .pwm)
try await client.analogWrite(channel: 3, value: 512)   // auto-upgrades to extended if needed

// Extended analog: pins ≥ 16, or values wider than 14 bits (e.g. servo microseconds).
try await client.extendedAnalogWrite(pin: 9, value: 1500)
```

```swift
// One-shot analog read. Enables sampling for the channel, awaits one sample, restores.
// `channel` is the analog CHANNEL index (A0 = 0, …) from queryAnalogMapping(), NOT a pin.
try await client.setPinMode(34, mode: .analog)
let raw = try await client.analogRead(channel: 0)               // 0…1023 / 0…4095, etc.
let raw2 = try await client.analogRead(channel: 0, timeout: .seconds(1))
```

```swift
// Push-style sampling: report a channel every sampling interval (see §5 to change it).
// Samples arrive as .analog(channel:value:) on `client.messages`.
try await client.reportAnalogChannel(0, enable: true)
// …later…
try await client.reportAnalogChannel(0, enable: false)
```

---

## 5. System

```swift
// Re-initialise the device (clears modes/reporting; tasks live in RAM and are wiped).
try await client.systemReset()

// Change how often analog channels are sampled (default ~19 ms on stock firmware).
try await client.setSamplingInterval(.milliseconds(100))

// Send a string to the device (surfaces in the firmware's string handler).
try await client.sendString("hello board")
```

---

## 6. Queries

All queries are `async throws` round-trips that resolve when the device replies.

```swift
let v = try await client.queryProtocolVersion()    // ProtocolVersion(major, minor)
print("Firmata \(v)")                              // CustomStringConvertible → "2.8"

let fw = try await client.queryFirmware()          // FirmwareInfo(major, minor, name)
print("\(fw.name) v\(fw.major).\(fw.minor)")

// Per-pin supported modes + resolutions, indexed by pin number.
let caps: [[PinCapability]] = try await client.queryCapabilities()
let pwmPins = caps.indices.filter { p in caps[p].contains { $0.mode == .pwm } }

// Map digital pin → analog channel (0x7F = not analog).
let mapping = try await client.queryAnalogMapping()

// Current mode + value of a pin. For outputs, `value` is the last written level;
// for digital inputs, 1 means pull-up enabled.
let s = try await client.queryPinState(pin: 13)    // PinState(pin, mode, value)
print("pin \(s.pin) mode=\(s.mode) value=\(s.value)")
```

---

## 7. I2C

```swift
// Configure once before any I2C traffic. The optional delay sits between a register
// write and the following read.
try await client.configureI2C(delay: .microseconds(0))

// Write bytes (7-bit address here; pass is10Bit: true for 10-bit addressing).
// Example: SSD1306 OLED at 0x3C — control byte 0x00 (command), then 0xAE (display off).
try await client.i2cWrite(address: 0x3C, data: [0x00, 0xAE])

// One-shot read; optionally write a peripheral register address first (auto-restart).
let reply = try await client.i2cReadOnce(address: 0x48, registerAddress: 0x00, count: 2)
print("temp bytes: \(reply.data)")                 // I2CReply(address, registerAddress, data)

// Continuous reads — replies arrive as .i2cReply on `client.messages` (see §2).
try await client.i2cStartReading(address: 0x48, registerAddress: 0x00, count: 2)
// …later…
try await client.i2cStopReading(address: 0x48)
```

> **`registerAddress` ≠ the board's logic registers.** Here `registerAddress` is a
> sub-address *inside the I2C peripheral* (e.g. a sensor's config/data register). It has
> nothing to do with the device's 16 on-device logic registers (`R0`–`R15`,
> ``TaskNumberRegister``) used by scheduler tasks (§12) — those are a separate, unrelated
> concept that just happens to share the word "register".

---

## 8. Live internet requests

Ask the device to make an HTTP(S) request **over its own Wi-Fi** and return the
result to you. (`https://` certs are validated on-device against bundled root CAs.)
The board blocks briefly while it fetches, then replies. *Non-standard extension.*

```swift
// GET → HTTPResponse(status, body). status == 0 means Wi-Fi down / request failed.
let resp = try await client.httpGet("https://api.example.com/quote/SPY")
guard resp.isSuccess else { return }               // isSuccess == 2xx

// Inspect the body on the HOST with Foundation:
let obj = try resp.json()                           // Any (NSDictionary/NSArray/…)

struct Quote: Decodable { let symbol: String; let price: Double }
let quote = try resp.decode(Quote.self)             // Codable convenience

// POST with a JSON body (Content-Type: application/json):
let created = try await client.httpPost("https://api.example.com/log",
                                        body: #"{"event":"boot"}"#,
                                        timeout: .seconds(20))
print(created.status)
```

> For requests that must keep running **after you disconnect**, record an `httpGet`
> into a *task* instead (see §17), where the body is inspected on the device.

---

## 9. Scheduler tasks — high-level `uploadTask`

A **task** is a recording of the same verbs you'd call live (pin writes, delays, …)
that the board stores and replays **autonomously** — it keeps running after you
disconnect. You don't `await` each step; you *record* them synchronously in the
closure, and one `await uploadTask(...)` ships the whole program.

```swift
// Blink pin 2 every 500 ms, entirely on the board — survives disconnect.
try await client.uploadTask(id: 2, startDelay: .zero, repeatEvery: .milliseconds(500)) { board in
    board.setPinMode(.pin(2), mode: .output)   // recorded, not sent now
    board.digitalWrite(pin: .pin(2), high: true)
    board.delay(.milliseconds(500))                 // the BOARD waits here while running
    board.digitalWrite(pin: .pin(2), high: false)
}
await client.disconnect()                // the LED keeps blinking
```

```swift
// One-shot (no repeat): runs once, then the task is removed.
try await client.uploadTask(id: 5) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.digitalWrite(pin: .pin(2), high: true)
}

// Parameters:
//   id            0–127. Reusing an id REPLACES that task (e.g. use the pin number).
//   startDelay  delay before the first run (0 = immediately).
//   repeatEvery non-nil → loop forever with this gap; nil → run once.
```

---

## 10. Scheduler tasks — low-level building blocks

`uploadTask` is sugar over these; reach for them only if you need manual control.

```swift
try await client.resetTasks()                       // delete EVERY task on the device
try await client.deleteTask(id: 7)                  // delete one (no-op if absent)

// Build raw task bytes yourself with a recorder, then create + append + schedule.
let rec = FirmataTaskRecorder()
rec.setPinMode(2, mode: .output)
rec.digitalWrite(pin: 2, high: true)
let data = rec.bytes                                 // the recorded program

try await client.createTask(id: 7, length: data.count)
try await client.addToTask(id: 7, data: data)        // may be called in chunks
try await client.scheduleTask(id: 7, delayMs: 0)     // start now (resets position)

// Introspection:
let ids: [UInt8] = try await client.queryAllTasks()  // ids of stored tasks
let task: SchedulerTask? = try await client.queryTask(id: 7)  // nil if not found
if let t = task { print("task \(t.id): \(t.length) bytes, pos \(t.position)") }
```

---

## 11. Recorder: the basic task verbs

Inside a task closure (`board`) you get a `FirmataTaskRecorder`. These mirror the
live calls but **capture bytes** instead of sending — so they're synchronous (no `await`).

```swift
try await client.uploadTask(id: 1) { board in
    // Digital / PWM / timing — same shapes as the live client:
    board.setPinMode(.pin(2), mode: .output)
    board.digitalWrite(pin: .pin(2), high: true)
    board.writeDigitalPort(0, pinMask: 0xFF)
    board.analogWrite(channel: .channel(3), value: 200)
    board.delay(.milliseconds(1000))                       // the board waits here while running

    // I2C from a task (drive an OLED etc. with no host connected):
    board.configureI2C(delay: .microseconds(0))       // begin the bus (once)
    board.i2cWrite(address: 0x3C, data: [0x00, 0xAE])
    // (no i2c reads in a task — their reply would have no host to receive it)
}
```

### Tasks that spawn tasks — `addTask` / `deleteTask`

A recording can contain a whole *other* task: `board.addTask(id:...) { child in … }`
records "replace, upload, and schedule task `id`" as a step. When the device executes
it, the child task is created and scheduled exactly as if a host had called
`uploadTask` — but nobody needs to be connected. `board.deleteTask(id:)` stops one.

```swift
// Check a sensor every minute; while it's hot, an alarm task blinks on its own.
try await client.uploadTask(id: 1, repeatEvery: .seconds(60)) { board in
    let temp = board.i2cRead(address: 0x48, registerAddress: 0x00, count: 2)
    board.ifTrue(temp, .greaterThan, .number(2800), then: {
        $0.addTask(id: 2, repeatEvery: .milliseconds(250)) { alarm in
            alarm.digitalWrite(pin: .pin(2), high: true)
            alarm.delay(.milliseconds(125))
            alarm.digitalWrite(pin: .pin(2), high: false)
        }
    }, elseDo: {
        $0.deleteTask(id: 2)          // cooled down — remove the alarm
    })
}
```

Rules of the road:

- **Replace-on-run.** Every execution of the `addTask` step deletes and re-uploads
  the child, so a repeating parent restarts its child once per period. (Delete of a
  missing id is a silent no-op, so the first run is clean.)
- **Registers and slots are global** across all tasks — the child inherits the
  parent's auto-allocation cursors (like an `ifTrue` branch), so auto registers
  don't collide, but the 16-register budget is shared. Use pinned registers
  (`into: .reg(n)`) to pass values parent → child.
- **Budgets.** The child must fit `MAX_TASK_BYTES` (512) on its own, and its
  ~8/7-encoded upload messages also count toward the parent's 512.
- **Never reuse the parent's own id** for the child — replacing yourself while
  running is firmware-defined territory (the firmware refuses to reuse the
  running slot; use the host's `uploadTask` to replace a live task instead).
- `deleteTask(id:)` with the task's *own* id ends it after the current run.

---

## 12. On-device logic: registers + reads

The device has **16 Int32 registers** (`R0`–`R15`) and **8 float registers** (`F0`–`F7`),
shared across tasks and cleared by a system reset. *Non-standard extension.* You always
name them with the typed operands — `.reg(0…15)` (``TaskNumberRegister``) / `.freg(0…7)`
(``TaskFloatRegister``) — never a bare index. (These are the board's own scratch registers;
they're unrelated to an I2C peripheral's `registerAddress` in §7, which just shares the name.)

```swift
try await client.uploadTask(id: 1) { board in
    // Load a constant into a register you name:
    board.setRegister(.reg(3), to: .number(512))               // R3 = 512

    // Reads INTO a register you choose:
    board.setPinMode(.pin(7), mode: .input)
    board.digitalRead(into: .boolReg(1), pin: .pin(7))          // R1 = digitalRead(7)  (0/1)
    board.analogRead(into: .reg(2), channel: .channel(0))       // R2 = analogRead(A0)  (channel index!)

    // Reads that RETURN an auto-allocated register as a typed operand, so you can drop
    // them straight into a comparison. Auto registers descend R15 → R0.
    let pressed: TaskBool   = board.digitalRead(pin: .pin(7))     // -> TaskBool
    let light:   TaskNumber = board.analogRead(channel: .channel(0))  // -> TaskNumber
    board.ifTrue(pressed) { $0.digitalWrite(pin: .pin(2), high: true) }   // see §14
    _ = light
}
```

---

## 13. The operand model (typed)

Everything the logic ops consume/return is a `TaskOperand`. Concrete conforming
types carry the *static type* so the API tells you what a value is:

| Type | Made by | Meaning |
|---|---|---|
| `TaskNumber` | `.number(_)`, `.reg(_)`, arithmetic, `json.getNumber/getType/getSize`, `string.length/indexOf/toInt` | Int32 value / register |
| `TaskFloat` | `.float(_)`, `.freg(_)`, float arithmetic, `json.getFloat` | Float value / register |
| `TaskBool` | `.bool(_)`, `compare(…)`, `digitalRead(pin:)`, `json.bodyContains`, `string.equals/contains`, `isValid()` | 0/1 result |
| `TaskResponseBody` | `response.body`, `board.json.snapshot` | a response-body handle (not a comparable value) |
| `TaskString` | `json.getString`, `string.createString` | a captured string value, for the `board.string` ops |

```swift
// Literals — use these almost everywhere:
let a  = TaskOperand.number(200)   // Int32 literal     (or: TaskNumberLiteral(rawValue: 200))
let f  = TaskOperand.float(1.5)    // Float literal     (or: TaskFloatLiteral(rawValue: 1.5))
let on = TaskOperand.bool(true)    // boolean literal   (or: TaskBoolLiteral(rawValue: true))

// Naming a register explicitly (advanced; the auto-allocator usually handles this):
let r3 = TaskOperand.reg(3)        // int register R3 as an operand
let f0 = TaskOperand.freg(0)       // float register F0 as an operand

// Because these types all conform to TaskOperand, a typed result flows into any op:
//   board.ifTrue(board.analogRead(channel: .channel(0)), .greaterThan, .number(512)) { … }
// If either side of a comparison/op is a float, the device promotes to float.
```

---

## 14. `ifTrue` and `compare`

`ifTrue` records an `if`/`else` the **device** evaluates while the task runs. Branches
are themselves recorder closures and may nest. *Forward-only — a task can't loop/hang.*

```swift
try await client.uploadTask(id: 1) { board in
    board.setPinMode(.pin(2), mode: .output)
    board.analogRead(into: .reg(0), channel: .channel(0))               // R0 = A0

    // (a) Compare two operands with a TaskComparison:
    //     .equal .notEqual .lessThan .greaterThan .lessOrEqual .greaterOrEqual
    board.ifTrue(.reg(0), .greaterThan, .number(512),
        then:   { $0.digitalWrite(pin: .pin(2), high: true) },     // runs if R0 > 512
        elseDo: { $0.digitalWrite(pin: .pin(2), high: false) })    // optional else

    // (b) Branch directly on a TaskBool (a predicate / digitalRead / compare / isValid):
    let pressed = board.digitalRead(pin: .pin(7))             // -> TaskBool
    board.ifTrue(pressed) { $0.digitalWrite(pin: .pin(2), high: true) }   // "if true (non-zero)"
}
```

```swift
// `compare` MATERIALISES a reusable boolean in a register, so you can store it once
// and branch on it several times (instead of repeating the comparison inline).
// Backed by the firmware CMP op (0x27).
try await client.uploadTask(id: 1) { board in
    let warm = board.compare(board.analogRead(channel: .channel(0)), .greaterThan, .number(2000)) // -> TaskBool
    board.ifTrue(warm) { $0.digitalWrite(pin: .pin(2), high: true) }
    board.ifTrue(warm) { $0.digitalWrite(pin: .pin(4), high: true) }   // reuse, no recompute
    // compare(_:_:_:into:) — pass `into:` to choose the result register yourself.
}
```

---

## 15. Arithmetic — integer and float

```swift
try await client.uploadTask(id: 1) { board in
    // Integer ops → TaskNumber (result register auto-allocated, or pass into:).
    // 64-bit intermediates avoid overflow; ÷ and % by zero yield 0.
    let sum  = board.add(.reg(0), .number(5))           // R? = R0 + 5
    let diff = board.subtract(sum, .number(1))
    let prod = board.multiply(.reg(0), .reg(1))
    let quot = board.divide(prod, .number(2), into: .reg(6))  // explicit destination R6
    let rem  = board.modulo(.reg(0), .number(10))
    _ = (diff, quot, rem)

    // In place: pass the same register as an operand AND as `into:` — the result is
    // written back to it, so no extra register is used.  R0 = R0 + 5:
    board.add(.reg(0), .number(5), into: .reg(0))

    // Float ops → TaskFloat. 8 float registers F0–F7. ints promote to float.
    board.setFloatRegister(.freg(0), to: .float(100.0))                // F0 = 100.0
    let scaled = board.multiplyFloat(.freg(0), .float(1.5))   // F? = F0 * 1.5
    let added  = board.addFloat(scaled, .float(0.25))
    let sub    = board.subtractFloat(added, .float(0.1))
    let div    = board.divideFloat(sub, .float(2.0))    // ÷0 → 0
    _ = div
}
```

---

## 16. Heap stats

```swift
try await client.uploadTask(id: 1) { board in
    // Read free heap + largest contiguous block into registers, to gate an allocation
    // (e.g. a snapshot) on available memory. Returns a tuple of TaskNumbers.
    let mem = board.heapStats()                          // (free:, largest:)  auto-allocated
    board.ifTrue(mem.free, .greaterThan, .number(8192)) { _ in
        // …safe to do something memory-hungry…
    }
    // Or pick registers: board.heapStats(freeInto: .reg(10), largestInto: .reg(11))
}
```

---

## 17. Internet inside a task

`httpGet`/`httpPost` recorded into a task return a **`TaskHTTPResponse`**: branch on
`.status`, and pass `.body` (a `TaskResponseBody`) to the `board.json` inspection ops (§18).
The full body is retained on the device for inspection — no host needed.

```swift
// Every minute: green LED if SPY is up on the day, red if down — no host connected.
try await client.uploadTask(id: 5, repeatEvery: .seconds(60)) { board in
    board.setPinMode(.pin(2), mode: .output); board.setPinMode(.pin(4), mode: .output)

    let spy = board.httpGet("https://example.com/quote/SPY")   // -> TaskHTTPResponse
    // Pull a fractional JSON number into an Int32 register, scaled ×100 (so -0.42 → -42).
    let pct = board.json.getNumber(spy.body, "changePercent", scaledBy: 2)

    board.ifTrue(spy.status, .equal, .number(200)) {           // only act on HTTP 200
        $0.ifTrue(pct, .greaterThan, .number(0),
            then:   { $0.digitalWrite(pin: .pin(2), high: true);  $0.digitalWrite(pin: .pin(4), high: false) },
            elseDo: { $0.digitalWrite(pin: .pin(2), high: false); $0.digitalWrite(pin: .pin(4), high: true) })
    }
}
// httpPost in a task: board.httpPost(url, body: "…", statusInto: nil) -> TaskHTTPResponse
```

> While a host is connected, a task's HTTP result *also* arrives as
> `.httpResponse(status:body:)` on `client.messages` (§2).

---

## 18. JSON inspection on the device

`board.json.*` walks the **full** retained body in place (no parse-size cap) and writes
a typed result register. `path` is dotted/indexed:
`quoteResponse.result[0].regularMarketChangePercent`.

```swift
try await client.uploadTask(id: 6) { board in
    let r = board.httpGet("https://example.com/data")
    let body = r.body                                // TaskResponseBody handle (§19)

    // Numbers:
    let n  = board.json.getNumber(body, "count")                 // -> TaskNumber
    let n2 = board.json.getNumber(body, "price", scaledBy: 2,    // ×100, truncated
                               into: .reg(8), found: .reg(9))             // explicit dst + "found" reg
    let fv = board.json.getFloat(body, "regularMarketPrice")     // -> TaskFloat

    // Whole-body substring test (→ TaskBool 0/1):
    let raw    = board.json.bodyContains(body, "\"halted\":true")

    // Shape checks before extracting:
    let kind = board.json.getType(body, "result[0]")    // -> TaskJSONType (typed)
    board.ifTrue(kind, is: .number) { _ in /* the value at that path is a number */ }
    let span = board.json.getSize(body, "result")       // byte length of the value span

    // String *values*: navigate with getString, then use board.string (next section).
    let currency = board.json.getString(body, "currency")    // -> TaskString
    let isUSD    = board.string.equals(currency, "USD")      // -> TaskBool

    _ = (n, n2, fv, raw, kind, span, currency, isUSD)
}
```

```swift
// getType returns a typed TaskJSONType — branch on it with ifTrue(_:is:):
//   board.ifTrue(kind, is: .string) { … }
// TaskJSONValueType cases: .missing .object .array .string .number .bool .null
```

For **string values**, navigate with `board.json.getString` → a `TaskString`, then use the
`board.string` ops — see §20.

---

## 19. Snapshots & staleness

A body handle (`response.body`) is **borrowed**: it reads the device's live body, which
a *later* request overwrites. Two tools manage that:

```swift
try await client.uploadTask(id: 7) { board in
    let a = board.httpGet(urlA)
    board.json.snapshot(a.body)                       // IN-PLACE: a.body now OWNS a slot
    //   ^ upgrades the handle so it survives later requests; subsequent json ops on
    //     a.body read the persisted copy. (No return value — it mutates a.body.)

    let b = board.httpGet(urlB)                        // a's *live* body would now be stale

    let aVal = board.json.getNumber(a.body, "price")      // from A (snapshot — still valid)
    let bVal = board.json.getNumber(b.body, "price")      // from B (live)
    board.ifTrue(bVal, .greaterThan, aVal) { $0.digitalWrite(pin: .pin(2), high: true) }

    board.json.free(a.body)                            // release the snapshot slot (2 total)
}
```

```swift
// isValid(): record a TaskBool that is true while a BORROWED handle's live body is
// still the one captured at request time (false once a newer request replaces it). An
// owned snapshot is always valid. Under the hood: REQUEST_COUNT read + CMP vs captured gen.
try await client.uploadTask(id: 8) { board in
    let c = board.httpGet(urlC)
    let price = board.json.getNumber(c.body, "price")
    board.ifTrue(c.body.isValid()) {                   // only trust the read if still fresh
        $0.ifTrue(price, .greaterThan, .number(100)) { $0.digitalWrite(pin: .pin(2), high: true) }
    }
}
```

---

## 20. Strings — `board.string`

A **`TaskString`** feeds the `board.string` ops. Get one two ways:

- **From JSON** — `board.json.getString(body, "path")` captures a string value's content
  (unquoted) into a ``TaskStringSlot`` (§18). Reads the **live** body, so call it right after the
  `httpGet`.
- **Standalone** — `board.string.createString("literal")` loads a literal straight into a slot,
  no HTTP needed.

Either way the ops are identical:

```swift
try await client.uploadTask(id: 9) { board in
    // From a JSON field:
    let r = board.httpGet("https://example.com/status")   // {"msg":"42 ready"}
    let s = board.json.getString(r.body, "msg")           // TaskString for "42 ready"

    let len  = board.string.length(s)                     // -> TaskNumber (byte length)
    let ok   = board.string.contains(s, "ready")          // -> TaskBool
    let same = board.string.equals(s, "42 ready")         // -> TaskBool
    let at   = board.string.indexOf(s, "ready")           // -> TaskNumber (index, or -1)
    let n    = board.string.toInt(s, found: .reg(9))      // -> TaskNumber (leading int) + found flag
    board.ifTrue(ok) { $0.digitalWrite(pin: .pin(2), high: true) }
    board.string.free(s)                                   // release the slot when done
    _ = (len, same, at, n)

    // Standalone literal — no HTTP:
    let mode = board.string.createString("on")
    board.ifTrue(board.string.equals(mode, "on")) { $0.digitalWrite(pin: .pin(4), high: true) }
    mode.changeSlot(TaskStringSlot(9))                        // copy into a specific slot, rebind
    board.string.free(mode)
}
```

**Slots are typed and separate**: `TaskJSONSlot` (2: `0`–`1`) for `board.json.snapshot`, and
`TaskStringSlot` (10: `0`–`9`) for strings — both auto-allocated, passed explicitly as
`into: TaskJSONSlot(1)` / `into: TaskStringSlot(3)`, and released with `board.json.free` / `board.string.free`.
`s.changeSlot(TaskStringSlot(n))` copies a string into a given slot (and rebinds the handle).
Backed by firmware ops `0x2C` (getString) /
`0x2D` (createString) / `0x2E` (copy-slot), then `0x28`–`0x2B` / `0x18` for the ops.

---

## 21. Custom transport

Conform to `FirmataTransport` to drive the client over anything (serial, raw TCP, a mock):

```swift
import Network
import SwiftFirmataClient

final class DirectTCPTransport: FirmataTransport, @unchecked Sendable {
    private let conn: NWConnection
    init(host: String, port: UInt16) {
        conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
    }

    // Write raw bytes to the device.
    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed {
                if let e = $0 { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    // Yield received bytes; finish (or throw) when the connection closes.
    func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { cont in
            conn.stateUpdateHandler = { if case .failed(let e) = $0 { cont.finish(throwing: e) } }
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, done, err in
                    if let err { cont.finish(throwing: err); return }
                    data?.forEach { cont.yield($0) }
                    if done { cont.finish() } else { loop() }
                }
            }
            conn.start(queue: .global())
            loop()
            cont.onTermination = { _ in self.conn.cancel() }
        }
    }
}

let client = FirmataClient(transport: DirectTCPTransport(host: "192.168.1.146", port: 3030))
await client.connect()
```

---

## 22. Type reference

```swift
// ── Pin modes ───────────────────────────────────────────────────────────────
enum PinMode: UInt8 { case input, output, analog, pwm, servo, shift, i2c,
                           oneWire, stepper, encoder, serial, inputPullup,
                           spi, sonar, tone, dht }

// ── Query / message payloads ─────────────────────────────────────────────────
struct ProtocolVersion { let major, minor: UInt8 }                  // "2.8"
struct FirmwareInfo    { let major, minor: UInt8; let name: String }
struct PinCapability   { let mode: PinMode; let resolution: UInt8 } // bits per mode
struct PinState        { let pin: UInt8; let mode: PinMode; let value: Int32 }
struct I2CReply        { let address, registerAddress: UInt16; let data: [UInt8] }

struct HTTPResponse {                  // live httpGet/httpPost result
    let status: Int                    // 0 = Wi-Fi down / failed
    let body: String
    var isSuccess: Bool                // 2xx
    func json(options:) throws -> Any  // Foundation object graph
    func decode<T: Decodable>(_:) throws -> T
}

// ── Messages stream ──────────────────────────────────────────────────────────
enum FirmataMessage {
    case analog(channel: UInt8, value: UInt16)
    case digital(port: UInt8, pinMask: UInt8)
    case protocolVersion(ProtocolVersion)
    case firmwareReport(FirmwareInfo)
    case capabilityResponse(pins: [[PinCapability]])
    case analogMappingResponse(channelByPin: [UInt8])
    case pinStateResponse(PinState)
    case stringData(String)
    case i2cReply(I2CReply)
    case extendedAnalog(pin: UInt8, value: Int32)
    case schedulerTaskList(taskIds: [UInt8])
    case schedulerTask(SchedulerTask)
    case schedulerError(taskId: UInt8)
    case httpResponse(status: Int, body: String)
    case unknownSysEx(id: UInt8, data: [UInt8])
}

struct WiFiStatus { let connected: Bool; let ip: String? }   // provisioning result

enum FirmataDisconnectReason { case localRequest, replacedByAnotherClient, transportClosed }
enum FirmataError: Error     { case transportClosed, invalidData, noResponse, wifiCredentialsRejected }

// ── Scheduler / logic extension ──────────────────────────────────────────────
struct SchedulerTask { let id: UInt8; let timeMs: UInt32; let length, position: Int; let data: [UInt8] }

protocol TaskOperand { /* base */ }
protocol TaskNumber: TaskOperand {}      // .number(_) / .reg(_)  (TaskNumberLiteral / TaskNumberRegister)
protocol TaskFloat:  TaskOperand {}      // .float(_)  / .freg(_) (TaskFloatLiteral / TaskFloatRegister)
protocol TaskBool:   TaskOperand {}      // .bool(_)   / compare / predicates / isValid()
final class TaskResponseBody {                    // a response-body handle (NOT an operand)
    func isValid() -> TaskBool
}
final class TaskString { /* a captured string, for board.string ops */ }
struct TaskHTTPResponse { let status: TaskNumberRegister; let body: TaskResponseBody }

struct TaskPin     { /* .pin(13)    */ }   // a board pin, by number (typed; recorder/task API)
struct TaskChannel { /* .channel(0) */ }   // an analog channel index A0=0… (typed; ≠ a pin)
struct TaskJSONSlot   { /* TaskJSONSlot(0)   — JSON snapshot slot 0–1   */ }
struct TaskStringSlot { /* TaskStringSlot(0) — string slot 0–9          */ }

// Live-client typed identities (separate types from the recorder's Task* above):
struct FirmataPin     { /* .pin(13)    */ }   // live FirmataClient pin
struct FirmataChannel { /* .channel(0) */ }   // live FirmataClient analog channel
// Live I/O takes bare UInt8 *or* these: client.digitalWrite(pin: 2, …) == client.digitalWrite(pin: .pin(2), …)

struct TaskJSONType { /* board.json.getType result; ifTrue(_, is: .string); is-a TaskNumber */ }

enum TaskComparison: UInt8 { case equal, notEqual, lessThan, greaterThan, lessOrEqual, greaterOrEqual }
enum TaskJSONValueType:  Int32  { case missing, object, array, string, number, bool, null }      // 0…6
```

> **Live vs. recorder.** `client.digitalRead(pin:)` / `analogRead(channel:)` return a
> *value* (`Bool` / `UInt16`) right now. The recorder's `board.digitalRead(pin:)` /
> `analogRead(channel:)` instead return an **operand** (a register) for use in on-device
> logic, because a task has no host to hand a value back to.

## 23. Wi-Fi provisioning (encrypted, over BLE)

Hand the board its Wi-Fi credentials at runtime — typically over **BLE**, before Wi-Fi is up — so a prebuilt firmware (placeholder creds) can join *your* network with no rebuild. The handshake is an ephemeral **X25519 ECDH → HKDF-SHA256 → AES-256-GCM**, so the password is never sent in the clear (no BLE pairing required).

```swift
let client = FirmataClient(transport: BLETransport())   // Wi-Fi is down → connect over BLE
await client.connect()

// Encrypted set + (re)connect. Returns once the device reports back.
// Throws .wifiCredentialsRejected if the handshake failed to authenticate
// (wrong key / tampered frame), or .noResponse on timeout.
let status = try await client.provisionWiFi(ssid: "MyNetwork", password: "hunter2")
print(status.connected, status.ip ?? "—")               // e.g. true 192.168.1.50

let now = try await client.queryWiFiStatus()            // check without changing anything
try await client.forgetWiFi()                           // clear stored creds → revert to compile-time
```

- Provisioned creds are saved on the device (**NVS**) and **override** the compile-time
  `WIFI_SSID` / `WIFI_PASS` on every boot.
- It's transport-agnostic (works over Bonjour/TCP too), but BLE is the point — you use it
  precisely when Wi-Fi isn't up yet.
- **Security:** defeats a passive eavesdropper with forward secrecy; with no pairing it is
  *not* hardened against an active real-time man-in-the-middle during the handshake.
