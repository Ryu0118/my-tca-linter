@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-view-store-send: detects store.send(...) calls inside TCA Views")
struct TCAViewStoreSendRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-view-store-send"))
    }

    // MARK: - Violation tests

    @Test("error when store.send is called inside a struct conforming to View")
    func detectsStoreSendInViewConformance() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: CounterReducer.self)
        struct CounterView: View {
            var store: StoreOf<CounterReducer>

            var body: some View {
                Button("Increment") {
                    store.send(.view(.incrementTapped))
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when store.send is called inside a struct whose name ends with View")
    func detectsStoreSendInViewNameConvention() async {
        let source = """
        import ComposableArchitecture

        struct CounterView {
            var store: StoreOf<CounterReducer>

            var body: some View {
                Button("Tap") {
                    store.send(.view(.tapped))
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when store?.send is called inside a TCA View (optional chaining)")
    func detectsOptionalChainingSend() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct ItemView: View {
            var store: StoreOf<ItemReducer>?

            var body: some View {
                Button("Tap") {
                    store?.send(.view(.tapped))
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when store!.send is called inside a TCA View (force unwrap)")
    func detectsForceUnwrapSend() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct ItemView: View {
            var store: StoreOf<ItemReducer>?

            var body: some View {
                Button("Tap") {
                    store!.send(.view(.tapped))
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when store.send is called inside an extension on a View-named type")
    func detectsStoreSendInViewExtension() async {
        let source = """
        import ComposableArchitecture

        extension CounterView {
            func handleTap() {
                store.send(.view(.tapped))
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for multiple store.send calls — each is reported")
    func detectsMultipleStoreSendCalls() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var store: StoreOf<FooReducer>

            var body: some View {
                VStack {
                    Button("A") { store.send(.view(.aTapped)) }
                    Button("B") { store.send(.view(.bTapped)) }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    // MARK: - Non-violation tests

    @Test("no error when send() is called directly via @ViewAction (correct pattern)")
    func ignoresViewActionSend() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: CounterReducer.self)
        struct CounterView: View {
            @Bindable var store: StoreOf<CounterReducer>

            var body: some View {
                Button("Increment") {
                    send(.incrementTapped)
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when store.send is called outside a View type")
    func ignoresStoreSendOutsideView() async {
        let source = """
        import ComposableArchitecture

        struct CounterViewModel {
            var store: StoreOf<CounterReducer>

            func increment() {
                store.send(.incrementTapped)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when store.send is called in a non-View extension")
    func ignoresStoreSendInNonViewExtension() async {
        let source = """
        import ComposableArchitecture

        extension CounterViewModel {
            func increment() {
                store.send(.incrementTapped)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for empty file")
    func emptyFile() async {
        let diagnostics = await rule.lint(source: "")
        #expect(diagnostics.isEmpty)
    }
}
