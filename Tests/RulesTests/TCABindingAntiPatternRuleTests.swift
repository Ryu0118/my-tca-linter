@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-binding-anti-pattern: detects Binding(get:set:) with send() in TCA Views")
struct TCABindingAntiPatternRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-binding-anti-pattern"))
    }

    // MARK: - Violation tests

    @Test("error when Binding(get:set:) uses store.send in a TCA View")
    func detectsStoreSend() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: SomeReducer.self)
        struct SomeView: View {
            @Bindable var store: StoreOf<SomeReducer>

            var body: some View {
                Toggle(
                    "Label",
                    isOn: Binding(
                        get: { store.isEnabled },
                        set: { store.send(.view(.toggled($0))) }
                    )
                )
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when Binding(get:set:) uses send() without store in a TCA View")
    func detectsSendWithoutStore() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: SomeReducer.self)
        struct SomeView: View {
            @Bindable var store: StoreOf<SomeReducer>

            var body: some View {
                DatePicker(
                    "Date",
                    selection: Binding(
                        get: { store.date },
                        set: { send(.dateChanged($0)) }
                    )
                )
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    // MARK: - Non-violation tests

    @Test("no error when Binding set closure does not call send")
    func ignoresNonSendBinding() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: SomeReducer.self)
        struct SomeView: View {
            @Bindable var store: StoreOf<SomeReducer>

            var body: some View {
                TextField(
                    "Tag",
                    text: Binding(
                        get: { store.filterTag ?? "" },
                        set: { newValue in self.localState = newValue }
                    )
                )
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when Binding(get:set:) appears in a non-TCA file")
    func ignoresNonTCAFile() async {
        let source = """
        import SwiftUI

        struct PlainView: View {
            @State var value = false

            var body: some View {
                Toggle(
                    "Label",
                    isOn: Binding(
                        get: { value },
                        set: { send(.toggled($0)) }
                    )
                )
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when using $store binding directly (correct pattern)")
    func ignoresCorrectPattern() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        @ViewAction(for: SomeReducer.self)
        struct SomeView: View {
            @Bindable var store: StoreOf<SomeReducer>

            var body: some View {
                Toggle("Label", isOn: $store.isEnabled)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }
}
