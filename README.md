# my-tca-linter

A collection of lint rules for [The Composable Architecture (TCA)](https://github.com/pointfreeco/swift-composable-architecture), built on [swift-ast-lint](https://github.com/Ryu0118/swift-ast-lint).

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Ryu0118/my-tca-linter/main/install.sh | bash
```

### Nest ([mtj0928/nest](https://github.com/mtj0928/nest))

```bash
nest install Ryu0118/my-tca-linter
```

### Mise ([jdx/mise](https://github.com/jdx/mise))

```bash
mise use -g ubi:Ryu0118/my-tca-linter
```

### Build from source

Requires Swift 6.2+ and macOS 15+.

```bash
git clone https://github.com/Ryu0118/my-tca-linter.git
cd my-tca-linter
swift build -c release
```

## Rules

| Rule ID | Severity | Description |
|---------|----------|-------------|
| `tca-binding-anti-pattern` | error | Flags `Binding(get:set:)` whose `set:` closure calls `send()` or `store.send()` in a TCA View |
| `tca-view-store-send` | error | Flags direct `store.send(...)` calls inside TCA Views |
| `tca-no-action-as-function` | error | Flags `return .send(...)` used to call another case of the same Reducer's `Action` as if it were a function |
| `tca-view-reducer-same-file` | error | Flags a single file that declares both a SwiftUI `View` and a TCA Reducer |

### tca-binding-anti-pattern

In TCA, `@Bindable` + `BindingAction` + `BindingReducer()` lets you bind store state directly with `$store.xxx`. Using `Binding(get:set:)` with a `send()` call in the `set:` closure bypasses this mechanism and should be replaced.

Detected in files that contain `@ViewAction` or `StoreOf<`.

```swift
// ❌ error
Toggle(
    "Enabled",
    isOn: Binding(
        get: { store.isEnabled },
        set: { store.send(.view(.toggled($0))) }
    )
)

// ✅
Toggle("Enabled", isOn: $store.isEnabled)
```

### tca-view-store-send

In TCA Views, actions must be dispatched via the `send(_:)` function provided by `@ViewAction`. Calling `store.send(...)` directly bypasses the `@ViewAction` wrapper.

**Detected in:**
- `struct X: View` — explicit `View` conformance
- `struct XxxView` — type name ending with `"View"`
- `extension XxxView` — extension on a `*View`-named type

Also flags `store?.send(...)` and `store!.send(...)`.

```swift
// ❌ error
struct CounterView: View {
    var body: some View {
        Button("Increment") {
            store.send(.view(.incrementTapped))
        }
    }
}

// ✅
@ViewAction(for: CounterReducer.self)
struct CounterView: View {
    @Bindable var store: StoreOf<CounterReducer>

    var body: some View {
        Button("Increment") {
            send(.incrementTapped)
        }
    }
}
```

### tca-no-action-as-function

In TCA, `Action` represents a state transition, not a callable function. Returning `.send(...)` from one `case` of a `Reduce` to trigger another `case` of the *same* Reducer is an anti-pattern — it turns the action log into noise for what is really a plain function call.

Sending to a genuinely different destination is legitimate and is not flagged:
- `.send(.delegate(...))` — a child-to-parent delegate notification.
- `.send(.child(...))` where `child` is scoped to another Reducer via `Scope`, `.ifLet`, or `.forEach` in the same `body` — a parent-to-child action forward.

To avoid false positives, a violation is only reported when there is positive evidence that the sent case is a sibling case of the same Reducer's own `Action` — either it's declared in a nested `Action` enum, or matched by a `case .caseName` pattern in the same `Reduce` switch. When this can't be determined, nothing is reported. Only a directly-returned `.send(...)` is inspected; a send wrapped in a combinator (e.g. `return .merge(.send(.a), .send(.b))`) is not unwrapped and is not flagged.

```swift
// ❌ error
case .someAction:
    return .send(.internal(.updateState))

case .internal(.updateState):
    state.value = newValue
    return .none

// ✅
case .someAction:
    state.value = newValue
    return .none

// ✅ forwarding to a Scoped child Reducer
case .someButtonTapped:
    return .send(.timeline(.refresh))

// ✅ delegate notification to the parent
case .closeButtonTapped:
    return .send(.delegate(.didClose))
```

### tca-view-reducer-same-file

The TCA architecture convention keeps a feature's View and its Reducer in separate files (`FooView.swift` / `FooReducer.swift`). Co-locating them couples the UI and the state machine and lets the file grow into a hard-to-navigate blob. When a single file declares both, a diagnostic is reported on **each** Reducer declaration.

**A View is:**
- `struct X: View` / `class X: View` — exact `View` conformance
- `extension X: View` — an extension adding `View` conformance

`View` is matched by exact token equality, so `ViewModifier`, a type merely *named* `FooView` without conformance, and custom `SomethingView` protocols are **not** treated as Views.

**A Reducer is:** a type with the `@Reducer` attribute, a type conforming to `Reducer`/`ReducerProtocol`, or an `extension` adding such conformance.

Files with only Views, or only Reducers — no matter how many, including a parent `@Reducer` with a nested `@Reducer enum Destination`/`Path` — are not flagged.

```swift
// ❌ error — FooView.swift declares both
struct FooView: View {
    var body: some View { ... }
}

@Reducer
struct FooReducer {
    // ...
}

// ✅ split across two files
// FooView.swift
struct FooView: View {
    var body: some View { ... }
}

// FooReducer.swift
@Reducer
struct FooReducer {
    // ...
}
```

## Usage

### Run the linter

```bash
swift run --package-path /path/to/my-tca-linter swift-ast-lint /path/to/your/Sources
```

### Apply auto-fixes

```bash
swift run --package-path /path/to/my-tca-linter swift-ast-lint /path/to/your/Sources --fix
```

### Configure via YAML

Place a `.swift-ast-lint.yml` in the root of your project:

```yaml
rules:
  tca-view-store-send:
    include:
      - "Sources/**"
    exclude:
      - "**/*Generated.swift"
```

## Requirements

- Swift 6.2+
- macOS 15+

## License

MIT
