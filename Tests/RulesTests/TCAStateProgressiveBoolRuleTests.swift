@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

@Suite("tca-state-progressive-bool: detects stored `isXXXing` Bool flags in Reducer State")
struct TCAStateProgressiveBoolRuleTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try #require(rules.find(id: "tca-state-progressive-bool"))
    }

    // MARK: - Violation tests

    @Test("error for stored `var isLoading = false` in a @Reducer State")
    func detectsStoredBoolLiteralInReducerState() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        public struct MyReducer {
            public struct State: Equatable {
                var isLoading = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for annotated `var isSubmitting: Bool` in an @ObservableState struct")
    func detectsAnnotatedBoolInObservableState() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            @ObservableState
            struct State: Equatable {
                var isSubmitting: Bool = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for optional `var isLoading: Bool?`")
    func detectsOptionalBool() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var isLoading: Bool?
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test(
        "detects common progressive-form names",
        arguments: ["isEditing", "isRefreshing", "isSaving", "isRecording", "isOnboarding"]
    )
    func detectsProgressiveVariants(name: String) async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var \(name) = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1, "Expected violation for: \(name)")
    }

    @Test("reports each violating flag when multiple exist")
    func detectsMultipleFlags() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var isLoading = false
                var isSubmitting = false
                var title = ""
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    // MARK: - Non-violation tests

    @Test("no error for computed projection `var isLoading: Bool { ... }`")
    func ignoresComputedProjection() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var phase: Phase = .idle
                var isLoading: Bool { phase == .loading }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test(
        "no error for non-progressive names (domain facts)",
        arguments: ["isAllDay", "isPublic", "isExistingUser", "hasLoaded"]
    )
    func ignoresDomainFactBools(name: String) async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var \(name) = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty, "Should not flag: \(name)")
    }

    @Test("no error for `isOngoing` in a domain model outside TCA")
    func ignoresDomainModelFile() async {
        let source = """
        import Foundation

        struct Event {
            var isOngoing = false
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for a struct named State in a file without @Reducer or @ObservableState")
    func ignoresNonTCAStateStruct() async {
        let source = """
        import Foundation

        struct State {
            var isLoading = false
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for non-Bool stored property with a matching name")
    func ignoresNonBoolType() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var isRefreshing: RefreshPhase = .idle
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for `let` constant")
    func ignoresLetConstant() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                let isTesting = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for stored Bool in a type nested inside State")
    func ignoresNestedTypeMembers() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                struct Draft {
                    var isSyncing = false
                }
                var draft = Draft()
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("still flags stored var with willSet/didSet observers")
    func detectsStoredVarWithObservers() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var isLoading = false {
                    didSet { print(isLoading) }
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("no error for a top-level struct State not nested in a Reducer, even if the file has @Reducer")
    func ignoresTopLevelStateInReducerFile() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
        }

        struct State {
            var isLoading = false
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for struct State nested in a non-Reducer type, even if the file has @Reducer")
    func ignoresStateInNonReducerType() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
        }

        struct GameEngine {
            struct State {
                var isRunning = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("error for State inside a legacy `struct Foo: Reducer` (protocol conformance, no macro)")
    func detectsLegacyReducerProtocolConformance() async {
        let source = """
        import ComposableArchitecture

        struct MyReducer: Reducer {
            struct State {
                var isLoading = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("no error for State in an extension of an unrelated type, even with an unrelated @Reducer in the file")
    func ignoresStateInExtensionOfUnrelatedType() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
        }

        extension SomeViewModel {
            struct State {
                var isLoading = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("error for State declared in an extension of a Reducer in a @Reducer file")
    func detectsStateInReducerExtension() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
        }

        extension MyReducer {
            struct State {
                var isLoading = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("empty file produces no diagnostics")
    func emptyFile() async {
        let diagnostics = await rule.lint(source: "")
        #expect(diagnostics.isEmpty)
    }

    @Test("diagnostic message mentions enum-based modeling")
    func messageContent() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct State {
                var isLoading = false
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("enum"))
    }
}
