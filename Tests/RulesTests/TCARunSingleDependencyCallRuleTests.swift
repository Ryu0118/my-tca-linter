@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-run-single-dependency-call: a `.run` effect must contain a single Client/UseCase call")
struct TCARunSingleDependencyCallRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-run-single-dependency-call"))
    }

    // MARK: - Violation tests

    @Test("error when a `.run` closure contains two Client calls")
    func detectsTwoClientCalls() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        try await analyticsClient.track(a)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("two diagnostics when a `.run` closure contains three Client calls")
    func detectsThreeClientCalls() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        let b = try await analyticsClient.track(a)
                        try await syncClient.push(b)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    @Test("error for mixed Client and UseCase suffixes")
    func detectsMixedSuffixes() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let user = try await userClient.fetch()
                        try await authUseCase.login(user)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for calls through `self.` and chained member access")
    func detectsSelfAndChainedAccess() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await self.userClient.fetch()
                        try await self.analyticsClient.track(a)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error when the second call is nested inside a `Result { }` closure")
    func detectsCallNestedInResult() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        let result = await Result {
                            try await analyticsClient.track(a)
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error when the second call is nested inside a task group closure")
    func detectsCallNestedInTaskGroup() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                try? await analyticsClient.track(a)
                            }
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for `Effect.run` spelled explicitly")
    func detectsExplicitEffectRun() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return Effect.run { send in
                        let a = try await userClient.fetch()
                        try await analyticsClient.track(a)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for `.run(priority:)` with two Client calls")
    func detectsRunWithPriority() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run(priority: .high) { send in
                        let a = try await userClient.fetch()
                        try await analyticsClient.track(a)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("nested `.run` (inner has two calls) is analyzed independently of the outer `.run`")
    func detectsNestedRunIndependently() async {
        // Outer `.run` has exactly one dependency call site (userClient.fetch),
        // and a nested `.run` with two sites — only the nested one violates.
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        return .run { send in
                            let b = try await analyticsClient.track(a)
                            try await syncClient.push(b)
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    // MARK: - Non-violation tests

    @Test("no violation for a `.run` with exactly one Client call")
    func allowsSingleClientCall() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        try await userClient.fetch()
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for one Client call plus multiple `send(...)` calls")
    func allowsOneClientCallWithSends() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        await send(.startedLoading)
                        let user = try await userClient.fetch()
                        await send(.loaded(user))
                        await send(.finished)
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for a for-await loop over a single `client.stream()` call")
    func allowsForAwaitStream() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        for await x in userClient.stream() {
                            await send(.received(x))
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for `clock.sleep()` plus one Client call (clock is not suffixed)")
    func allowsClockSleepPlusClientCall() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        try await clock.sleep(for: .seconds(1))
                        try await userClient.fetch()
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for two separate `.run` effects each with one Client call")
    func allowsTwoSeparateRunEffects() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .a:
                        return .run { send in
                            try await userClient.fetch()
                        }
                    case .b:
                        return .run { send in
                            try await analyticsClient.track()
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for a `.run`-like call with two Client calls outside any Reducer type")
    func allowsRunOutsideReducer() async {
        let source = """
        import ComposableArchitecture

        struct Helper {
            func doWork() -> Effect {
                return .run { send in
                    let a = try await userClient.fetch()
                    try await analyticsClient.track(a)
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for the same Client called once inside a `while` loop")
    func allowsSameClientInWhileLoop() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        while !done {
                            let page = try await userClient.fetchPage()
                            await send(.page(page))
                        }
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no violation for a chained call whose immediate receiver is not Client/UseCase-suffixed")
    func allowsDeepChainNonSuffixedReceiver() async {
        // `self.userClient.session.fetch()` — the immediate receiver is `session`,
        // not `userClient`, so it is not counted (conservative by design).
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    return .run { send in
                        let a = try await userClient.fetch()
                        try await self.userClient.session.refresh()
                    }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }
}
