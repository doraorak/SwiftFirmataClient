# Scheduler logic extension (this branch)

This branch (`nonstandard-scheduler-logic`) adds an **on-device logic** extension
on top of the Firmata Scheduler. `main` / `standard` (and every tagged release,
incl. `1.1.0`) are the plain standard-compliant client. This branch pairs with the
`ESP32Firmata` firmware's `nonstandard-scheduler-logic` branch.

The Scheduler **control protocol is unchanged** — tasks are still uploaded with the
standard `CREATE`/`ADD`/`SCHEDULE` messages. The logic lives in the task data and
rides under the reference scheduler's reserved `EXTENDED_SCHEDULER_COMMAND` (`0x7F`),
so a **standard** Firmata scheduler ignores it gracefully (the task runs, the
conditionals are no-ops — no crash). Other hosts won't *act on* these ops.

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

These emit ops under `SCHEDULER_DATA` → `EXTENDED_SCHEDULER_COMMAND` (`0x7B 0x7F …`).
The ops themselves aren't part of any Firmata spec, but they ride the reference
scheduler's documented extension command, so standard schedulers ignore them
rather than choking.
