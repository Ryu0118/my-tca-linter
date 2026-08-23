@testable import Rules
import SwiftASTLint
import SwiftASTLintTestSupport
import Testing

private func actionCaseConventionRule() throws -> any RuleProtocol {
    try #require(rules.find(id: "tca-action-case-convention"))
}

@Suite("tca-action-case-convention: flags cases that are neither a category, a scope nor a binding")
struct TCAActionCaseConventionRuleViolationTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try actionCaseConventionRule()
    }

    @Test("error for a domain case carrying a response payload")
    func detectsResponseCase() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case fetchResponse(Result<[Item], any Error>)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
    }

    @Test("error for a case with no associated value")
    func detectsCaseWithoutAssociatedValue() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case dismiss
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for a case with multiple labeled associated values")
    func detectsMultipleLabeledAssociatedValues() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case presentAlert(title: String, message: String)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for multiple associated values even when the first one is a child Action")
    func detectsMultipleAssociatedValuesWithChildAction() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case child(ChildReducer.Action, id: UUID)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("reports every violating case in the same Action")
    func detectsEveryViolatingCase() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case dismiss
                case fetchResponse(Result<[Item], any Error>)
                case presentAlert(title: String, message: String)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 3)
    }

    @Test("reports each element of a comma-separated case declaration")
    func detectsCommaSeparatedElements() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case dismiss, reload
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    @Test("error for a category case name with no associated value")
    func detectsCategoryCaseWithoutPayload() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error inside a legacy `struct Foo: Reducer` (protocol conformance, no macro)")
    func detectsLegacyReducerProtocolConformance() async {
        let source = """
        import ComposableArchitecture

        struct MyReducer: Reducer {
            enum Action {
                case dismiss
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for an Action declared in an extension of a Reducer in the same file")
    func detectsActionInReducerExtension() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {}

        extension MyReducer {
            enum Action {
                case dismiss
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for an Action declared in an extension that adds Reducer conformance")
    func detectsActionInReducerConformanceExtension() async {
        let source = """
        import ComposableArchitecture

        struct MyReducer {}

        extension MyReducer: Reducer {
            enum Action {
                case dismiss
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
    }

    @Test("error for qualified Reducer attributes and conformances")
    func detectsQualifiedReducerDeclarations() async {
        let source = """
        import ComposableArchitecture

        @ComposableArchitecture.Reducer
        struct MacroReducer {
            enum Action {
                case dismiss
            }
        }

        struct ProtocolReducer: ComposableArchitecture.Reducer {
            enum Action {
                case dismiss
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 2)
    }

    @Test("diagnostic message names the offending case")
    func messageNamesCase() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case fetchResponse(Result<[Item], any Error>)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("fetchResponse"))
    }
}

@Suite("tca-action-case-convention: category, scope, presentation and binding cases are allowed")
struct TCAActionCaseConventionRuleAllowedTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try actionCaseConventionRule()
    }

    @Test("no error for the three category cases")
    func allowsCategoryCases() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action: ViewAction, Sendable {
                case view(ViewAction)
                case internalAction(InternalAction)
                case delegate(DelegateAction)
            }

            enum ViewAction: Sendable {
                case onAppear
                case closeButtonTapped
            }

            enum InternalAction: Sendable {
                case fetchResponse(Result<[Item], any Error>)
            }

            enum DelegateAction: Sendable {
                case didFinish
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test(
        "no error for scope cases",
        arguments: [
            "case child(ChildReducer.Action)",
            "case timeline(TimelineReducer.Action)",
            "case items(IdentifiedActionOf<ItemReducer>)",
            "case items(IdentifiedAction<Item.ID, ItemReducer.Action>)",
            "case path(StackActionOf<Path>)",
            "case path(StackAction<Path.State, Path.Action>)",
            "case destination(PresentationAction<Destination.Action>)",
            "case destination(ComposableArchitecture.PresentationAction<Destination.Action>)",
        ]
    )
    func allowsScopeCases(caseDeclaration: String) async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                \(caseDeclaration)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty, "Should not flag: \(caseDeclaration)")
    }

    @Test(
        "no error for PresentationAction wrapping a plain (non-Reducer) enum",
        arguments: [
            "case alert(PresentationAction<Alert>)",
            "case dialog(PresentationAction<Dialog>)",
            "case confirmationDialog(PresentationAction<ConfirmationDialog>)",
            "case alert(PresentationAction<Never>)",
        ]
    )
    func allowsPlainEnumPresentation(caseDeclaration: String) async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                \(caseDeclaration)
            }

            @CasePathable
            enum Alert: Equatable {
                case confirmTapped
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty, "Should not flag: \(caseDeclaration)")
    }

    @Test(
        "no error for the BindableAction requirement",
        arguments: [
            "case binding(BindingAction<State>)",
            "case binding(BindingAction<MyReducer.State>)",
        ]
    )
    func allowsBinding(caseDeclaration: String) async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action: BindableAction {
                case view(ViewAction)
                \(caseDeclaration)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty, "Should not flag: \(caseDeclaration)")
    }

    @Test("no error for an optional child Action payload")
    func allowsOptionalChildAction() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case child(ChildReducer.Action?)
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }
}

@Suite("tca-action-case-convention: only root Reducer Action enums are inspected, and args are configurable")
struct TCAActionCaseConventionRuleScopeAndConfigTests {
    private let rule: any RuleProtocol

    init() throws {
        rule = try actionCaseConventionRule()
    }

    @Test("no error for cases declared in the nested ViewAction / InternalAction / DelegateAction enums")
    func ignoresNestedCategoryEnums() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum ViewAction {
                case onAppear
                case textChanged(String)
            }

            enum InternalAction {
                case fetchResponse(Result<[Item], any Error>)
            }

            enum DelegateAction {
                case didClose
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for an `Action` enum that is not nested in a Reducer")
    func ignoresNonReducerAction() async {
        let source = """
        import Foundation

        enum Action {
            case dismiss
            case presentAlert(title: String, message: String)
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for an `Action` enum nested in a non-Reducer type in a file that also has a Reducer")
    func ignoresActionInUnrelatedType() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {}

        struct GameEngine {
            enum Action {
                case tick
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for an Action enum nested in a helper type inside a Reducer")
    func ignoresActionInNestedHelperType() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            struct Helper {
                enum Action {
                    case tick
                }
            }
        }
        """
        let diagnostics = await rule.lint(source: source)
        #expect(diagnostics.isEmpty)
    }

    @Test("no error for an `@Reducer enum Destination` (case-per-child enum Reducer)")
    func ignoresEnumReducerDestination() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        enum Destination {
            case detail(DetailReducer)
            case settings(SettingsReducer)
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

    @Test("`internal` is flagged by default but allowed once configured as a category case name")
    func categoryCaseNamesOverride() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case `internal`(InternalAction)
                case delegate(DelegateAction)
            }
        }
        """
        let defaultDiagnostics = await rule.lint(source: source)
        #expect(defaultDiagnostics.count == 1)

        let overridden = await rule.lint(
            source: source,
            argsYAML: "category_case_names: [\"view\", \"internal\", \"delegate\"]\n"
        )
        #expect(overridden.isEmpty)
    }

    @Test("additional allowed case names suppress project-specific exceptions")
    func additionalAllowedCaseNames() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case legacy(LegacyPayload)
            }
        }
        """
        let defaultDiagnostics = await rule.lint(source: source)
        #expect(defaultDiagnostics.count == 1)

        let overridden = await rule.lint(
            source: source,
            argsYAML: "additional_allowed_case_names: [\"legacy\"]\n"
        )
        #expect(overridden.isEmpty)
    }

    @Test("a partial YAML override keeps the defaults for the other arguments")
    func partialYAMLOverrideKeepsDefaults() async {
        let source = """
        import ComposableArchitecture

        @Reducer
        struct MyReducer {
            enum Action {
                case view(ViewAction)
                case internalAction(InternalAction)
                case delegate(DelegateAction)
                case legacy(LegacyPayload)
            }
        }
        """
        let diagnostics = await rule.lint(
            source: source,
            argsYAML: "additional_allowed_case_names: [\"legacy\"]\n"
        )
        #expect(diagnostics.isEmpty)
    }
}
