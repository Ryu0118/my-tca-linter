@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-view-reducer-same-file: flags files declaring both a View and a Reducer")
struct TCAViewReducerSameFileRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-view-reducer-same-file"))
    }

    // MARK: - Violation tests

    @Test("error for `struct FooView: View` + `@Reducer struct FooReducer` in one file")
    func detectsViewAndMacroReducer() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for `struct FooView: View` + `struct Foo: Reducer` (protocol conformance, no macro)")
    func detectsViewAndProtocolReducer() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        struct Foo: Reducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for View + legacy `ReducerProtocol` conformance")
    func detectsViewAndReducerProtocol() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        struct Foo: ReducerProtocol {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for View + top-level `@Reducer enum Destination`")
    func detectsViewAndTopLevelReducerEnum() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        enum Destination {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for View + nested `@Reducer enum Destination` inside another Reducer")
    func detectsViewAndNestedReducerEnum() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct FooReducer {
            @Reducer
            enum Destination {
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        // One diagnostic per Reducer declaration: FooReducer + nested Destination.
        #expect(diagnostics.count == 2)
    }

    @Test("error for `extension Foo: View` in a file that also declares a Reducer")
    func detectsViewExtensionAndReducer() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct Foo {
        }

        extension Foo: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("one diagnostic per Reducer declaration when multiple reducers share a file with a view")
    func detectsMultipleReducersWithOneView() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct AReducer {
        }

        @Reducer
        struct BReducer {
        }

        struct CReducer: Reducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 3)
        #expect(diagnostics.allSatisfy { $0.severity == .error })
    }

    @Test("error for `extension Foo: Reducer` conformance in a file with a View")
    func detectsReducerExtensionAndView() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        struct Foo {
        }

        extension Foo: Reducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for a `class`-based View plus a Reducer")
    func detectsClassViewAndReducer() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        final class FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    // MARK: - Non-violation tests

    @Test("no error for a file with only Views, including helper subviews")
    func ignoresViewsOnly() async {
        let source = """
        import SwiftUI

        struct FooView: View {
            var body: some View {
                HeaderView()
            }
        }

        struct HeaderView: View {
            var body: some View { EmptyView() }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a file with only Reducers, including a nested @Reducer enum Destination")
    func ignoresReducersOnly() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct FooReducer {
            @Reducer
            enum Destination {
            }

            @Reducer
            enum Path {
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a View plus a ViewModifier (ViewModifier is not View)")
    func ignoresViewAndViewModifier() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        struct Shake: ViewModifier {
            func body(content: Content) -> some View { content }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a View plus plain helper structs and enums")
    func ignoresViewAndPlainHelpers() async {
        let source = """
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        struct Config {
            var title = ""
        }

        enum Direction {
            case up, down
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a struct named `SomethingView` without `: View` plus a Reducer")
    func ignoresNameEndingInViewWithoutConformance() async {
        let source = """
        import ComposableArchitecture

        struct SomethingView {
            var title = ""
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a type conforming to a custom `SomethingView` protocol plus a Reducer")
    func ignoresCustomViewSuffixProtocol() async {
        let source = """
        import ComposableArchitecture

        struct Foo: SomethingView {
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a file that is neither View nor Reducer")
    func ignoresUnrelatedFile() async {
        let source = """
        import Foundation

        struct Event {
            var title = ""
        }

        enum Direction {
            case up, down
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("empty file produces no diagnostics")
    func emptyFile() async {
        let diagnostics = await rule.lint(source: "")
        #expect(diagnostics.isEmpty)
    }

    @Test("diagnostic message advises separating the View and Reducer into different files")
    func messageContent() async {
        let source = """
        import ComposableArchitecture
        import SwiftUI

        struct FooView: View {
            var body: some View { EmptyView() }
        }

        @Reducer
        struct FooReducer {
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("separate"))
    }
}
