# ⚠️ Non-standard branch — scheduler logic extension

This branch (`nonstandard-scheduler-logic`) **deliberately steps outside the Firmata
standard.** `main` and the `standard` branch (and every tagged release, incl.
`1.1.0`) are standard-compliant Firmata. This branch is **not** — it pairs with the
`ESP32Firmata` firmware's `nonstandard-scheduler-logic` branch and works with
nothing else.

## What it adds

`FirmataTaskRecorder` gains on-device **logic** so a scheduled task can decide
things by itself instead of being a flat list of actions:

```swift
try await client.uploadTask(id: 1, repeatEveryMs: 1000) { t in
    t.readAnalog(into: 0, channel: 0)                  // R0 = analog A0
    t.ifTrue(.reg(0), .greaterThan, .const(512),
        then: { $0.digitalWrite(pin: 2, value: true) },   // bright → LED on
        elseDo: { $0.digitalWrite(pin: 2, value: false) }
    )
}
// runs on the device with nobody connected
```

- `setRegister(_:to:)`, `readDigital(into:pin:)`, `readAnalog(into:channel:)`
- `ifTrue(_:_:_:then:elseDo:)` — operands are `.reg(n)` or `.const(v)`; comparisons
  `== != < > <= >=`
- 16 global Int32 registers on the device; **`if`/`else` only** (forward skips, no
  arbitrary jumps/loops), so a task can never hang the board.

These emit extra sub-commands under the Scheduler SysEx (`0x7B`, range `0x10+`)
that only this project's firmware understands. The encoding is **not** part of any
Firmata spec.
