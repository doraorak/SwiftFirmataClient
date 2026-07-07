# Firmata Suite — Implementation Notes & Code Style (Swift)

A living reference to *how the code is built* — class/struct/actor choices, argument shapes,
internal naming, and the conventions each layer follows. The goal is to make the implementation
style easy to inspect and to propose changes against. Covers the three Swift projects:

- **client** — `SwiftFirmataClient` (this repo): async `actor` client + `FirmataTaskRecorder`.
- **fw** — `ESP32FirmataSwift`: Embedded Swift firmware for the ESP32 (Xtensa), one `-wmo` module.
- **app** — `FirmataController`: SwiftUI macOS app (task builder + live control).

(The C++ firmware `ESP32Firmata` is a byte-for-byte mirror of the Swift fw and is intentionally
out of scope here. The `SwiftFirmataIR` module package follows the client's extension pattern —
see *Module packages* below.)

**Convention: new features are logged at the TOP of the next section, newest first.** The
*Enduring conventions* below change rarely; the log captures how each recent feature was built.

---

## Recent additions (newest first)

### Style pass — module handlers, constant masks, less legacy code
- **fw module system is now class-based.** `Modules.swift` defines `protocol ModuleHandler: AnyObject`
  (`id/major/minor/name`, `handle(_:_:)`, `tick()`) and a `let modules: [ModuleHandler]` registry;
  `IRModuleHandler` (in `IRModule.swift`) owns the IR state and implements it. Discovery (MODULE_QUERY)
  and dispatch/tick just iterate `modules` — adding a module is one array entry, no `switch`. (Verified:
  Embedded Swift supports the class-bound existential array.) Method names avoid shadowing the globals —
  the IR transmit method is `txFrame`, not `sendFrame` (that's the host-frame global).
- **Masks are constant-derived everywhere.** fw: `REG_MASK`/`FREG_MASK = UInt8(NUM_x_REGS - 1)`.
  client: `Sched.intRegisterMask`/`floatRegisterMask` (+ count-derived preconditions). A register-count
  change is one edit.
- **Legacy-support code removed** (new firmware ⇒ new client is the supported pairing): the
  `RegisterSnapshot` parser reads only the current 32+16 layout; `TaskValue` is back to synthesized
  `Codable` (no bare-int path). Old IR tasks with the pre-`TaskValue` bare-int code no longer load.
- **app builder:** the per-step view methods are `plainBlock`/`ifBlock`/`taskBlock`/`repeatBlock`
  (uniform); every "Drop here" zone is orange.

### Register file doubled → 32 int / 16 float, public/internal split (fw 2.15)
- fw: `NUM_SCHED_REGS 16→32`, `NUM_FLOAT_REGS 8→16` (RuntimeState.swift). Register-index masks
  widened `& 0x0F → & 0x1F` (int) everywhere they're *decoded*; float masks were already
  constant-derived (`& (NUM_FLOAT_REGS-1)`) so they auto-widened. Every `& 0x0F` in `Scheduler.swift`
  and `IRModule.swift` is a register index, so a blanket widen was safe there.
- client: the two conventions that isolate the halves — (1) public API caps user registers at 15
  (`.reg(n)`, compiler `checked(n, max: 15)`), (2) auto-allocation cursors moved into the internal
  range: values descend `R31↓`, HTTP generation ascends `R16↑`, floats descend `F15↓`. `operandBytes`
  and encode masks widened to `& 0x1F`/`& 0x0F`; init `precondition` relaxed to `<= 31`/`<= 15`.
- client: `RegisterSnapshot` parser (`FirmataParser`) reads the 32+16 layout (floats at wire index
  32-39) and exposes only the public subset (R0-15, F0-7).
- Style note this reinforced: **prefer constant-derived masks** (`& (NUM_x_REGS-1)`) over literals so
  a size bump is one edit. The int masks were literals and cost ~40 edits; the float masks were free.

### IR code from a register/variable — on-device NEC/RC6 encoding (fw 2.14, op 0x05)
- fw: `irEncodeNEC`/`irEncodeRC6` in `IRModule.swift` build the timing waveform *on the board* from a
  register value the host never sees (mirrors the host encoders). Op `0x05 <protocol> <srcReg>`.
- client: `FirmataTaskRecorder.irSendNEC/RC6(fromRegister:)` (in `SwiftFirmataIR`).
- app: the IR code field became a `TaskValue` (literal → host op 0x03; register/variable → op 0x05,
  dispatched in `TaskCompiler.irSend`). `TaskValue` uses synthesized `Codable`.

### Native counted-loop op + Repeat block (fw 2.13, SCHED_EXT_LOOP 0x34/0x35)
- fw: a per-`SchedTask` loop stack (`loopRemaining/Gap/Resume`, `MAX_LOOP_DEPTH`); `LOOP_END` jumps
  `pos` back and reuses `delayRunning(gap)` to suspend between iterations (the existing delay-suspend
  is the whole timing mechanism — no new scheduler state machine). `count==0` skips via a body-length
  field, same shape as `extIf`'s skip.
- client: `FirmataTaskRecorder.loop(_ count:gap:_ body:)` records `LOOP_BEGIN + body + LOOP_END`,
  back-patching the body length exactly like `ifTrue` patches its skip. (Named `loop`, **not**
  `repeatSteps` — "steps" is app-only vocabulary; the recorder speaks in ops/actions.)
- app: `TaskOp.repeatBlock(count:gapMs:steps:)` — a control-flow container rendered like `ifTrue`/
  `addTask` (nested `StepsEditor`), compiled by driving `rec.loop { … }`.

---

## Enduring conventions

### Cross-project architecture
- **Record on host, replay on device.** `FirmataTaskRecorder` emits the *exact* SysEx byte stream the
  firmware's scheduler replays. There is no separate task language — the recorder *is* the compiler.
  The app's `TaskCompiler` drives a recorder; it never emits bytes itself.
- **Wire protocol.** Standard Firmata SysEx. The task/logic extension lives under
  `SCHED_EXT_COMMAND (0x7F)` as ops `0x10–0x35`; the module subsystem under `MODULE_DATA (0x0D)`.
  Registers (R0-31) and float registers (F0-15) are shared device state.
- **Values are 7-bit-safe.** Multi-byte ints go out as little-endian 5-limb `encode7BitFirmata`;
  indices/small fields are single 7-bit bytes (register index uses 5 of the 7 bits).

### client — `SwiftFirmataClient`
**Types & concurrency**
- `public actor FirmataClient` — all device I/O; async methods, an `AsyncStream` `messages`, and a
  pluggable `public protocol FirmataTransport: Sendable`. Everything crossing the boundary is `Sendable`.
- `public final class FirmataTaskRecorder` — a *reference* type because it accumulates `var bytes`
  and allocation cursors as you record. The only non-`Sendable` public type; used synchronously.
- `public struct FirmataParser: Sendable` — incremental, fed one byte at a time, returns
  `FirmataMessage?`. Pure value type, no I/O.
- DTOs are small `public struct … : Sendable` (`RegisterSnapshot`, `HTTPResponse`, `PinState`,
  `SchedulerTask`, `ModuleInfo`, …). Protocol enums (`FirmataMessage`, `PinMode`) are `Sendable`.
- Constants live in **internal namespace enums** — `Cmd`, `SysEx`, `Sched`, `Module`, `WiFiCfg` —
  never loose top-level lets. (`Sched.extLoop`, `Cmd.startSysEx`.)

**Operand / register model** (the type-safe core of the task extension)
- Protocol hierarchy: `TaskOperand` → `{TaskRegister, TaskLiteral}` → `{TaskNumber, TaskFloat, TaskBool}`
  → concrete `TaskNumberLiteral/Register`, `TaskFloatLiteral/Register`, `TaskBoolLiteral/Register`.
- Each concrete operand exposes `var operandBytes: [UInt8]` (its own wire encoding: `[kind, …]`).
  Adding an operand kind = a new struct conforming to the right protocol, nothing else.
- User-facing construction via `TaskOperand where Self == …` factory extensions: `.reg(3)`, `.number(5)`,
  `.freg(1)`, `.boolReg(2)`. Register structs `precondition` their index range (bounds are a programmer
  error, not a runtime one).

**Recorder conventions**
- Ops append inline: `bytes += [Cmd.startSysEx, SysEx.schedulerData, Sched.extCommand, Sched.extX, …]`.
- Fixed message shapes are built by `private static func xMessage(...) -> [UInt8]` (e.g. `ifMessage`,
  `skipMessage`, `loopMessage`) so the byte layout for one op lives in one place.
- Block ops (`ifTrue`, `addTask`, `loop`) record the body into a **child recorder** created with
  `FirmataTaskRecorder(inheriting: self)`, then `adoptCursors(from: child)` so register/slot allocation
  is continuous across scopes and never reused. The body's byte length is back-patched into the header.
- **Auto-allocation vs pinned.** Value-producing methods take `into: T? = nil`; `nil` → `allocateRegister()`
  (internal R31↓). Naming: `nextAutoRegister` / `allocateRegister()` / `nextRequestCountRegister`.

**Argument-shape conventions**
- Pins/channels are typed wrappers, never bare `Int`: `FirmataPin` (`.pin(4)`), `FirmataChannel`,
  `TaskPin`. Durations are `Duration` (`.milliseconds(220)`), never bare ms.
- Destinations are trailing `into:` (optional = auto-allocate). Labels read as prose:
  `analogRead(channel:)`, `setRegister(_:to:)`, `ifTrue(_:_:_:then:elseDo:)`.
- Doc every public symbol with `///`, including a runnable one-liner where it helps.

### fw — `ESP32FirmataSwift` (Embedded Swift)
**Module & files**
- One module, compiled `-wmo -parse-as-library -enable-experimental-feature Embedded` from ~12 files
  (`FirmataProtocol`, `RuntimeState`, `Messaging`, `LiveProtocol`, `Encoder7Bit`, `Scheduler`,
  `Modules`, `IRModule`, `Session`, `Configuration`, `Transport`, `Main`). Because it's `-wmo`,
  declaration order *between* files doesn't matter — split by concern, list files in the CMake command.
- Sections inside a file use `/* ==== Title ==================== */` banners. Entry is
  `@_cdecl("sw_main")` in `Main.swift`; Swift owns the run loop.

**Style**
- Protocol constants are global `let SCREAMING_SNAKE` (`SCHED_EXT_LOOP`, `PIN_MODE_OUTPUT`,
  `NUM_SCHED_REGS`). Runtime state is global `var` (`regs`, `frameBuf`, `pinModes`) — one process,
  no instances to thread.
- Core is free functions over globals (`handleModuleData(_:_:)`, `checkDigitalInputs()`). Classes are
  used only where an entity owns state: `Scheduler`, `FirmataProtocol`, and each **module**.
- **Module system.** `Modules.swift` defines `protocol ModuleHandler: AnyObject` and a
  `let modules: [ModuleHandler]` registry. A module (`IRModuleHandler`) is a `final class` holding its
  own state, implementing `handle(_ payload:_ length:)` (its wire ops) and `tick()`. `moduleDispatch`/
  `moduleTick`/MODULE_QUERY iterate the registry — a new module is one array entry. The C++ firmware
  mirrors this (it also vendors a per-module file): an abstract `struct ModuleHandler` with pure
  virtuals + a `ModuleHandler* modules[]` registry. (A single-`.ino` firmware would keep free
  functions — the class treatment is only worth it once a module lives in its own file.)
- **No per-tick allocation.** Reused fixed buffers (`irRawBuf`, `irRxBuf`, `frameBuf[2048]`); handlers
  take `(_ payload: [UInt8], _ length: Int)` and index into them. Verbose locals (`payload`, `length`,
  `index`, `count`, `duration`) after the readability pass — no `p`/`n`/`k`.
- Hardware/radio access only through the C shim `fm_*` functions (`fm_rmt_tx`, `fm_millis`,
  `fm_http_get`); the shim is imported via the bridging header, so all files see it with no `import`.
- Op handlers are a `switch payload[0]` with `case 0xNN:` per op and a one-line comment naming the
  wire layout. Guard lengths (`if length >= N`), mask indices with the size-derived mask.
- Debug-only ops sit behind `#if IR_DEBUG` (compiled out of release).

**The task VM** (`Scheduler`)
- Flat bytecode with a program counter: `SchedTask.pos` indexes `data`; `execute()` feeds bytes to a
  replay `FirmataProtocol` and **suspends on any `time_ms` change** (that's how DELAY and loop-gaps
  work — resume next `tick()` from `pos`). Control flow is forward `skip()` (extIf/extSkip) plus the
  backward jump in `LOOP_END`. New stateful ops add fields to `SchedTask` (like the loop stack).

### app — `FirmataController` (SwiftUI, macOS)
**Model** (`TaskProgram.swift`)
- `indirect enum TaskOp: Codable, Equatable` — one case per builder action, ~1:1 with recorder methods.
  Control-flow cases carry nested `[TaskStep]` (`ifTrue`, `repeatBlock`, `addTask`).
- `struct TaskStep` wraps an op with `id: UUID` (its variable handle) + optional `note` (name),
  `register`/`slot`/`foundRegister` (pin an auto-output to explicit state). `TaskProgram` = id + name +
  schedule + `[TaskStep]`.
- `enum TaskValue` = `.number/.float/.bool/.variable(UUID)/.register(UInt8)` — a builder operand.
- **Codable evolution.** New optional fields are `T?` (synthesized `decodeIfPresent` → `nil` for old
  data, e.g. `TaskProgram.name`). Removing a case's fields is safe (synthesized decode ignores extra
  keys) — how old IR tasks load as single sends. Beyond that, back-compat isn't maintained: a matching
  firmware/app version pair is assumed.

**Compiler** (`TaskCompiler.swift`)
- `enum TaskCompiler` with `static func compile(_:) throws -> [UInt8]`. Walks steps into a real
  `FirmataTaskRecorder`; an `Env` maps `step.id → operand`. Errors are a typed
  `enum TaskCompileError: CustomStringConvertible`. Nested containers use the recorder's closures with a
  captured-`thrown` error trampoline (the recorder closures are non-throwing).

**Views**
- `TaskBuilderView` → `StepsEditor` (a `[TaskStep]` list) → `StepBlock` (one row; dispatches to
  `plainBlock` / `ifBlock` / `taskBlock` / `repeatBlock`). Container blocks render a nested
  `StepsEditor` at `depth+1`. Row chrome: drag handle, tap-to-edit title, an X quick-remove, and a
  right-click `contextMenu` with the full action set.
- Nested-list plumbing goes through `childLists(_:)` / `withChildLists(_:_:)` so containers are handled
  generically (add a container → extend both, plus `TaskScope`'s two walks).
- `ActionEditor` edits one step's scalar fields via a `@ViewBuilder var fields` switch (exhaustive — a
  new op needs a case). Operand fields use `OperandField` (`Binding<TaskValue>` + a menu to pick
  literal / variable / register).
- `TaskScope` = variable scoping/naming (what's visible to a step); `TaskSummary` = row text + SF Symbol
  per op. Both switch over `TaskOp` and must gain a case for a new op.
- `ControllerModel` is the `@MainActor ObservableObject` app state; persistence (saved programs) is
  JSON in `UserDefaults`.

### Module packages (e.g. `SwiftFirmataIR`)
- A separate SPM package that **depends on the client** and adds capability as `extension FirmataClient`
  / `extension FirmataTaskRecorder` / `extension FirmataMessage`, built on the generic
  `sendToModule(id:payload:)` / `moduleOp(id:payload:)` primitives. The module's own namespace
  (encoders, ids) is `internal`; the public surface is just the extensions. Same doc/arg conventions
  as the client.
