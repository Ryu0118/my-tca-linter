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
mise use -g github:Ryu0118/my-tca-linter
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
| `tca-run-single-dependency-call` | error | Flags a `.run` effect that performs more than one UseCase/Client call inside a TCA Reducer |
| `tca-action-case-convention` | error | Flags root Reducer `Action` cases that are neither a category (`view`/`internalAction`/`delegate`), a child Reducer scope, a presentation, nor the `BindableAction` binding requirement |

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
### tca-run-single-dependency-call

A `.run` effect should orchestrate a *single* dependency call. Composing several UseCase/Client calls (fetch, then track, then sync, ...) inside the Reducer's effect leaks business logic into the Reducer — the composition, its ordering, and its error handling belong in a UseCase the Reducer calls once. Keeping `.run` down to one call keeps the Reducer a thin dispatcher and makes the composed behavior independently testable.

Analyzed only inside types that look like a TCA Reducer (`@Reducer`-attributed, `Reducer`/`ReducerProtocol`-conforming, or an `extension` of such a type in the same file). A dependency call site is a call whose immediate receiver is an identifier ending in `Client` or `UseCase` (e.g. `userClient.fetch()`, `self.authUseCase.login()`). Calls to `send(...)`, `clock.sleep(...)`, `Task.sleep(...)`, and the `.run` call itself are not dependency calls. Each distinct call expression counts once, so a call inside a loop or a `for await x in client.stream()` sequence is a single site. Nested closures within the same `.run` (`Result { }`, `withTaskGroup { }`, ...) are inspected, but a nested `.run` is analyzed independently. When a single `.run` contains two or more dependency call sites, the second and each subsequent site is flagged.

**Known limitation:** detection is name-based on the `Client`/`UseCase` suffix. A dependency not following this convention is not detected (a false negative), which is the safe direction — this linter prefers missed detections over false positives.

```swift
// ❌ error
return .run { send in
    let user = try await userClient.fetch()
    try await analyticsClient.track(user)  // second dependency call in one .run
}

// ✅ compose the calls inside a UseCase
return .run { send in
    let user = try await profileUseCase.loadAndTrack()
    await send(.loaded(user))
}
```

### tca-action-case-convention

A root Reducer `Action` should be a router, not a place to accumulate domain events directly. Every event belongs to one of three categories, each declared in its own nested enum: `view` (user intent), `internalAction` (effect results and other self-directed events) and `delegate` (notifications to the parent). A case declared straight on the root `Action` — instead of inside one of these three nested enums — breaks that split and makes the action log ambiguous about who sent what.

A case on the root `Action` is allowed when any of the following holds:

1. **Category** — the case name is one of `category_case_names` (default `view` / `internalAction` / `delegate`) and it has exactly one associated value.
2. **Child Reducer scope** — its single associated value is a `Foo.Action`, an `IdentifiedAction<...>` / `IdentifiedActionOf<...>`, or a `StackAction<...>` / `StackActionOf<...>`.
3. **Presentation** — its single associated value is a `PresentationAction<...>`. Both a scoped child Reducer (`PresentationAction<Destination.Action>`) and a plain, non-Reducer enum driving `.ifLet(\.$alert, action:)` (`PresentationAction<Alert>`) are legitimate, so the wrapped type is deliberately not inspected further.
4. **Binding** — its single associated value is a `BindingAction<...>`. `BindableAction` requires this case to live on the root `Action`, so it cannot be moved into a category enum.
5. **Extra allowance** — the case name is listed in `additional_allowed_case_names`, an escape hatch for project-specific exceptions that cannot be expressed by a payload type.

Only root Reducer `Action` enums are inspected (the nested `ViewAction` / `InternalAction` / `DelegateAction` enums, and `Action` enums that are not nested in a Reducer at all, are left alone).

```swift
// ❌ error — a domain event sitting directly on the root Action
enum Action {
    case view(ViewAction)
    case internalAction(InternalAction)
    case delegate(DelegateAction)
    case fetchResponse(Result<[Item], any Error>)  // should live in InternalAction
}

// ✅ every non-scope, non-binding case lives in one of the three category enums
enum Action: BindableAction {
    case view(ViewAction)
    case internalAction(InternalAction)
    case delegate(DelegateAction)
    case binding(BindingAction<State>)
    case destination(PresentationAction<Destination.Action>)

    enum ViewAction { case onAppear }
    enum InternalAction { case fetchResponse(Result<[Item], any Error>) }
    enum DelegateAction { case finished }
}
```

Configure via YAML when a project spells the categories differently or needs project-specific exceptions:

```yaml
rules:
  tca-action-case-convention:
    category_case_names: ["view", "internal", "delegate"]
    additional_allowed_case_names: ["legacy"]
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
