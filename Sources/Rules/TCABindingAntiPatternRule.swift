import SwiftASTLint
import SwiftSyntax

/// Detects `Binding(get:set:)` patterns where the `set:` closure calls `store.send(` or `send(`
/// inside a TCA View (identified by `@ViewAction` or `StoreOf<` in the file).
///
/// These should be replaced with `$store.xxx` bindings via `@Bindable` + `BindingAction` + `BindingReducer()`.
///
/// **Bad**
/// ```swift
/// Toggle(
///     "Label",
///     isOn: Binding(
///         get: { store.isEnabled },
///         set: { store.send(.view(.toggled($0))) }
///     )
/// )
/// ```
///
/// **Good**
/// ```swift
/// Toggle("Label", isOn: $store.isEnabled)
/// ```
let tcaBindingAntiPatternRule = Rule(id: "tca-binding-anti-pattern") { file, context in
    let fileText = file.description
    let isTCAView = fileText.contains("@ViewAction") || fileText.contains("StoreOf<")
    guard isTCAView else { return }

    let visitor = TCABindingVisitor(context: context)
    visitor.walk(file)
}

private final class TCABindingVisitor: SyntaxVisitor {
    let context: LintContext

    init(context: LintContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isBindingCall(node),
              let setArgument = findSetArgument(node)
        else { return .visitChildren }

        let setBody = setArgument.expression.description
        guard setBody.contains("store.send(") || setBody.contains("send(") else {
            return .visitChildren
        }

        context.report(
            on: node,
            message: "Do not use `Binding(get:set:)` with `send()` in a TCA View. "
                + "Use `$store.xxx` bindings with `@Bindable`, `BindingAction`, and `BindingReducer()` instead.",
            severity: .error
        )
        return .visitChildren
    }

    private func isBindingCall(_ node: FunctionCallExprSyntax) -> Bool {
        let callee = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return callee == "Binding" || callee.hasPrefix("Binding<")
    }

    private func findSetArgument(_ node: FunctionCallExprSyntax) -> LabeledExprSyntax? {
        let hasGet = node.arguments.contains { $0.label?.text == "get" }
        guard hasGet else { return nil }
        return node.arguments.first { $0.label?.text == "set" }
    }
}
