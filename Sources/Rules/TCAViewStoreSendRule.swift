import SwiftASTLint
import SwiftSyntax

/// Detects direct `store.send(...)` calls inside TCA Views.
///
/// In TCA Views, actions must be dispatched via the `send(_:)` function provided by
/// `@ViewAction`, not via `store.send(...)` directly. Calling `store.send` from a View
/// bypasses the `@ViewAction` wrapper and breaks the intended architecture.
///
/// **Detection criteria — any of the following:**
/// - `struct X: View` (explicit View conformance in inheritance clause)
/// - `struct XxxView` (type name ends with "View" by convention)
/// - `extension XxxView` (extension on a type whose name ends with "View")
///
/// **Bad**
/// ```swift
/// struct CounterView: View {
///     var body: some View {
///         Button("Increment") {
///             store.send(.view(.incrementTapped))  // ❌
///         }
///     }
/// }
/// ```
///
/// **Good**
/// ```swift
/// @ViewAction(for: CounterReducer.self)
/// struct CounterView: View {
///     var body: some View {
///         Button("Increment") {
///             send(.incrementTapped)  // ✅
///         }
///     }
/// }
/// ```
///
/// - Note: `store?.send(...)` and `store!.send(...)` are also flagged as the same anti-pattern.
let tcaViewStoreSendRule = Rule(id: "tca-view-store-send") { file, context in
    let visitor = ViewStoreSendVisitor(context: context)
    visitor.walk(file)
}

// MARK: - Outer visitor: finds TCA View type declarations

private final class ViewStoreSendVisitor: SyntaxVisitor {
    let context: LintContext

    init(context: LintContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if isViewConformance(node) || isViewNameConvention(node.name.text) {
            StoreSendDetector(context: context).walk(Syntax(node.memberBlock))
        }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.extendedType.description.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("View") {
            StoreSendDetector(context: context).walk(Syntax(node.memberBlock))
        }
        return .visitChildren
    }

    // MARK: - Helpers

    /// Returns true when the struct explicitly conforms to `View`.
    private func isViewConformance(_ node: StructDeclSyntax) -> Bool {
        guard let inheritance = node.inheritanceClause else { return false }
        return inheritance.inheritedTypes.contains { type in
            type.type.description.trimmingCharacters(in: .whitespacesAndNewlines) == "View"
        }
    }

    /// Returns true when the type name ends with "View" by naming convention.
    private func isViewNameConvention(_ name: String) -> Bool {
        name.hasSuffix("View")
    }
}

// MARK: - Inner visitor: detects store.send(...) calls

private final class StoreSendDetector: SyntaxVisitor {
    let context: LintContext

    init(context: LintContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        guard memberAccess.declName.baseName.text == "send" else { return .visitChildren }

        var baseExpr = memberAccess.base
        if let opt = baseExpr?.as(OptionalChainingExprSyntax.self) { baseExpr = opt.expression }
        if let force = baseExpr?.as(ForceUnwrapExprSyntax.self) { baseExpr = force.expression }
        let base = baseExpr?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard base == "store" || base.hasSuffix(".store") else { return .visitChildren }

        context.report(
            on: node,
            message: "Do not call `store.send(...)` directly in a TCA View. "
                + "Use `@ViewAction` and call `send(...)` instead.",
            severity: .error
        )
        return .visitChildren
    }
}
