@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-no-action-as-function: detects return .send(...) used as a function call within the same Reducer")
struct TCANoActionAsFunctionRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-no-action-as-function"))
    }

    // MARK: - Violation tests

    @Test("error when sending a sibling case declared in the nested Action enum")
    func detectsSiblingCaseViaActionEnum() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}

            enum Action {
                case someAction
                case updateState
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .someAction:
                        return .send(.updateState)
                    case .updateState:
                        state.value = 1
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when sending a nested sibling case, matched via switch case pattern")
    func detectsNestedSiblingCaseViaSwitchPattern() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case someAction
                case `internal`(Internal)
                enum Internal {
                    case updateState
                }
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .someAction:
                        return .send(.internal(.updateState))
                    case .internal(.updateState):
                        state.value = 1
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error when the same-Reducer send is nested inside an if statement")
    func detectsSiblingCaseInsideNestedIf() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case someAction
                case updateState
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .someAction:
                        if state.isReady {
                            return .send(.updateState)
                        }
                        return .none
                    case .updateState:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for multiple same-Reducer sends — each is reported")
    func detectsMultipleSameReducerSends() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case first
                case second
                case third
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .first:
                        return .send(.second)
                    case .second:
                        return .send(.third)
                    case .third:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    @Test("error when the Reducer is detected via explicit Reducer conformance (no @Reducer attribute)")
    func detectsViaExplicitConformance() async {
        let source = """
        struct SomeReducer: Reducer {
            struct State: Equatable {}
            enum Action {
                case someAction
                case updateState
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .someAction:
                        return .send(.updateState)
                    case .updateState:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    // MARK: - Non-violation tests

    @Test("no error for .send(.delegate(...)) — delegate notification is always allowed")
    func ignoresDelegateSend() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case closeButtonTapped
                case delegate(Delegate)
                enum Delegate {
                    case didClose
                }
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .closeButtonTapped:
                        return .send(.delegate(.didClose))
                    case .delegate:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when sending to a child scoped via Scope with shorthand key path")
    func ignoresScopedChildShorthand() async {
        let source = """
        @Reducer
        struct ParentReducer {
            struct State: Equatable { var timeline: TimelineReducer.State = .init() }
            enum Action {
                case someButtonTapped
                case timeline(TimelineReducer.Action)
            }

            var body: some ReducerOf<Self> {
                Scope(state: \\.timeline, action: \\.timeline) {
                    TimelineReducer()
                }
                Reduce { state, action in
                    switch action {
                    case .someButtonTapped:
                        return .send(.timeline(.refresh))
                    case .timeline:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when sending to a child scoped via Scope with fully-qualified key path")
    func ignoresScopedChildFullyQualified() async {
        let source = """
        @Reducer
        struct ParentReducer {
            struct State: Equatable { var timeline: TimelineReducer.State = .init() }
            enum Action {
                case someButtonTapped
                case timeline(TimelineReducer.Action)
            }

            var body: some ReducerOf<Self> {
                Scope(state: \\.timeline, action: \\.ParentReducer.Action.timeline) {
                    TimelineReducer()
                }
                Reduce { state, action in
                    switch action {
                    case .someButtonTapped:
                        return .send(.timeline(.refresh))
                    case .timeline:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when sending to a destination managed via .ifLet")
    func ignoresIfLetDestination() async {
        let source = """
        @Reducer
        struct ParentReducer {
            struct State: Equatable { @Presents var destination: Destination.State? }
            enum Action {
                case addButtonTapped
                case destination(PresentationAction<Destination.Action>)
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .addButtonTapped:
                        return .send(.destination(.presented(.add(.onAppear))))
                    case .destination:
                        return .none
                    }
                }
                .ifLet(\\.$destination, action: \\.destination) {
                    Destination.body
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when sending to a path element managed via .forEach")
    func ignoresForEachPath() async {
        let source = """
        @Reducer
        struct ParentReducer {
            struct State: Equatable { var path: StackState<Path.State> = .init() }
            enum Action {
                case rowTapped
                case path(StackActionOf<Path>)
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .rowTapped:
                        return .send(.path(.push(id: 0, state: .detail(.init()))))
                    case .path:
                        return .none
                    }
                }
                .forEach(\\.path, action: \\.path) {
                    Path.body
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for await send(...) inside a .run effect (not a direct return)")
    func ignoresSendInsideRunEffect() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case onAppear
                case dataLoaded(String)
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .onAppear:
                        return .run { send in
                            let data = try await client.fetch()
                            await send(.dataLoaded(data))
                        }
                    case .dataLoaded:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when the send destination cannot be confirmed as a sibling case (no evidence)")
    func ignoresUnresolvableDestination() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {}
            enum Action {
                case someAction
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .someAction:
                        return .send(.somethingElseEntirely)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error when the type is not a Reducer at all")
    func ignoresNonReducerType() async {
        let source = """
        struct SomePlainStruct {
            enum Action {
                case someAction
                case updateState
            }

            func reduce(action: Action) -> Effect<Action> {
                switch action {
                case .someAction:
                    return .send(.updateState)
                case .updateState:
                    return .none
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for BindingReducer() and EmptyReducer() combined with Reduce")
    func ignoresBindingAndEmptyReducerComposition() async {
        let source = """
        @Reducer
        struct SomeReducer {
            struct State: Equatable {
                @BindingState var text: String = ""
            }
            enum Action: BindableAction {
                case binding(BindingAction<State>)
                case someAction
                case updateState
            }

            var body: some ReducerOf<Self> {
                BindingReducer()
                EmptyReducer()
                Reduce { state, action in
                    switch action {
                    case .binding:
                        return .none
                    case .someAction:
                        return .send(.updateState)
                    case .updateState:
                        return .none
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("no error for empty file")
    func emptyFile() async {
        let diagnostics = await rule.lint(source: "")
        #expect(diagnostics.isEmpty)
    }
}
