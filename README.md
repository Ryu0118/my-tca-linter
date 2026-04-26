# my-tca-linter

A collection of lint rules for [The Composable Architecture (TCA)](https://github.com/pointfreeco/swift-composable-architecture), built on [swift-ast-lint](https://github.com/Ryu0118/swift-ast-lint).

## Installation

### Nest ([mtj0928/nest](https://github.com/mtj0928/nest))

```bash
nest install Ryu0118/my-tca-linter
```

### Mise ([jdx/mise](https://github.com/jdx/mise))

```bash
mise use -g ubi:Ryu0118/my-tca-linter
```

### Manual (curl)

Download the latest release archive for your platform from the [Releases](https://github.com/Ryu0118/my-tca-linter/releases/latest) page, then extract the binary:

```bash
# macOS (universal)
curl -fsSL https://github.com/Ryu0118/my-tca-linter/releases/latest/download/swift-ast-lint-<version>-darwin-universal.tar.gz | tar -xz
sudo mv swift-ast-lint /usr/local/bin/
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
