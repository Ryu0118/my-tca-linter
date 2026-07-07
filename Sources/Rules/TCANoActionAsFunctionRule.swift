import SwiftASTLint
import SwiftSyntax

/// Detects `return .send(.caseName(...))` used as a function call to another case of the
/// *same* Reducer's `Action` enum, inside a `Reduce { state, action in ... }` closure.
///
/// In TCA, `Action` represents a state transition, not a callable function. Returning
/// `.send(...)` to trigger another `case` in the same Reducer is an anti-pattern: it turns
/// the action log into noise and hides what is really a plain function call.
///
/// Sending to a genuinely different destination is legitimate and is **not** flagged:
/// - `.send(.delegate(...))` — a child-to-parent delegate notification.
/// - `.send(.child(...))` where `child` is scoped to another Reducer via `Scope`, `.ifLet`,
///   or `.forEach` in the same `body` — a parent-to-child action forward.
///
/// To avoid false positives (which are worse than missed detections for this rule), a
/// violation is only reported when there is **positive evidence** that the sent case is a
/// sibling case of the same Reducer's own `Action` enum: either the case appears in a nested
/// `Action` enum declaration, or it is matched by a `case .caseName` pattern in the same
/// `Reduce` switch statement. When neither can be determined, nothing is reported.
///
/// **Bad**
/// ```swift
/// case .someAction:
///     return .send(.internal(.updateState))  // ❌ same-Reducer case, used as a function call
///
/// case .internal(.updateState):
///     state.value = newValue
///     return .none
/// ```
///
/// **Good**
/// ```swift
/// case .someAction:
///     state.value = newValue  // ✅ mutate state directly
///     return .run { send in ... }
///
/// case .someButtonTapped:
///     return .send(.timeline(.refresh))  // ✅ forward to a Scoped child Reducer
///
/// case .closeButtonTapped:
///     return .send(.delegate(.didClose))  // ✅ delegate notification to the parent
/// ```
let tcaNoActionAsFunctionRule = Rule(id: "tca-no-action-as-function") { file, context in
    let visitor = ReducerTypeVisitor(context: context)
    visitor.walk(file)
}

// MARK: - Outer visitor: finds Reducer type declarations

/// Walks the file looking for types that look like a TCA Reducer, then analyzes their body.
private final class ReducerTypeVisitor: SyntaxVisitor {
    let context: LintContext

    init(context: LintContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause, members: node.memberBlock) {
            analyze(memberBlock: node.memberBlock)
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause, members: node.memberBlock) {
            analyze(memberBlock: node.memberBlock)
        }
        return .visitChildren
    }

    // MARK: - Helpers

    /// Returns true when the type looks like a TCA Reducer: `@Reducer` attribute, explicit
    /// `Reducer` conformance, or a `var body: some ReducerOf<Self>` / `var body: some Reducer<...>`.
    private func isReducerType(
        attributes: AttributeListSyntax,
        inheritance: InheritanceClauseSyntax?,
        members: MemberBlockSyntax,
    ) -> Bool {
        let hasReducerAttribute = attributes.contains { attribute in
            attribute.as(AttributeSyntax.self)?.attributeName.description
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Reducer"
        }
        if hasReducerAttribute { return true }

        let hasReducerConformance = inheritance?.inheritedTypes.contains { type in
            let name = type.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return name == "Reducer" || name.hasPrefix("Reducer<") || name.hasPrefix("Reducer,")
        } ?? false
        if hasReducerConformance { return true }

        return members.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }
            guard varDecl.bindings.first?.pattern.description
                .trimmingCharacters(in: .whitespacesAndNewlines) == "body"
            else { return false }
            let typeText = varDecl.bindings.first?.typeAnnotation?.type.description ?? ""
            return typeText.contains("ReducerOf") || typeText.contains("Reducer<") || typeText.contains(": Reducer")
        }
    }

    /// Analyzes a single Reducer type's member block: collects scoped-child action names and
    /// same-Reducer `Action` case names, then walks all `Reduce { state, action in ... }`
    /// closures for `return .send(...)` violations.
    private func analyze(memberBlock: MemberBlockSyntax) {
        let scopedChildCollector = ScopedChildActionCollector()
        scopedChildCollector.walk(Syntax(memberBlock))

        let actionCaseCollector = ActionCaseCollector()
        actionCaseCollector.walk(Syntax(memberBlock))

        let reduceVisitor = ReduceClosureVisitor(
            context: context,
            scopedChildNames: scopedChildCollector.childActionNames,
            actionCaseNames: actionCaseCollector.caseNames,
        )
        reduceVisitor.walk(Syntax(memberBlock))
    }
}

// MARK: - Scoped-child action name collector

/// Collects every identifier component appearing in the `action:` key path argument of
/// `Scope(state:action:)`, `.ifLet(_:action:)`, `.forEach(_:action:)`, and `.ifCaseLet(_:action:)`
/// calls anywhere in the Reducer's member block. All components are collected (not just the
/// first or last) so both `\.child` and `\.SomeAction.child` shorthand/fully-qualified forms are
/// handled without needing to resolve which is which — over-collecting only makes the rule more
/// permissive, which is the safe direction for a rule where false positives are costly.
private final class ScopedChildActionCollector: SyntaxVisitor {
    private(set) var childActionNames: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calleeName = calleeBaseName(node.calledExpression)
        guard ["Scope", "ifLet", "forEach", "ifCaseLet"].contains(calleeName) else {
            return .visitChildren
        }
        for argument in node.arguments where argument.label?.text == "action" {
            collectKeyPathComponents(from: argument.expression)
        }
        return .visitChildren
    }

    /// Returns the base name of a called expression, e.g. `Scope` for `Scope(...)` and
    /// `ifLet` for `.ifLet(...)` / `state.ifLet(...)`.
    private func calleeBaseName(_ expr: some ExprSyntaxProtocol) -> String {
        if let identifier = expr.as(DeclReferenceExprSyntax.self) {
            return identifier.baseName.text
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }
        return ""
    }

    /// Extracts every identifier segment from a key path expression such as `\.child` or
    /// `\.SomeAction.child`.
    private func collectKeyPathComponents(from expr: some ExprSyntaxProtocol) {
        guard let keyPath = expr.as(KeyPathExprSyntax.self) else { return }
        for component in keyPath.components {
            guard case let .property(property) = component.component else { continue }
            childActionNames.insert(property.declName.baseName.text)
        }
    }
}

// MARK: - Same-Reducer Action case name collector

/// Collects the top-level case names declared in `enum Action { ... }` (including nested
/// forms such as `case view(ViewAction)`) directly inside the Reducer's member block. Also
/// records case names matched by `case .caseName` patterns in `switch action` statements,
/// since these are a reliable local signal even when the `Action` enum is declared elsewhere
/// (e.g. an extension, or a separate file).
private final class ActionCaseCollector: SyntaxVisitor {
    private(set) var caseNames: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "Action" else { return .visitChildren }
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                caseNames.insert(element.name.text)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        for label in node.label.as(SwitchCaseLabelSyntax.self)?.caseItems ?? [] {
            collectCaseNames(from: label.pattern)
        }
        return .visitChildren
    }

    /// Extracts the leading case name from an expression pattern such as `.someCase` or
    /// `.someCase(let x)`.
    private func collectCaseNames(from pattern: PatternSyntax) {
        guard let exprPattern = pattern.as(ExpressionPatternSyntax.self) else { return }
        if let memberAccess = exprPattern.expression.as(MemberAccessExprSyntax.self) {
            caseNames.insert(memberAccess.declName.baseName.text)
        } else if let functionCall = exprPattern.expression.as(FunctionCallExprSyntax.self),
                  let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self)
        {
            caseNames.insert(memberAccess.declName.baseName.text)
        }
    }
}

// MARK: - Reduce closure visitor: detects return .send(.sibling(...)) violations

/// Walks every `Reduce { state, action in ... }` trailing closure and reports `return
/// .send(...)` calls whose destination case is a sibling case of the same Reducer.
///
/// Only `return .send(...)` — the `Effect` value directly returned from the reduce
/// function — is in scope. `await send(...)` inside a `.run { send in ... }` closure is a
/// different construct (an async effect notifying of a result) and cannot appear as a
/// `return` expression of type `Effect<Action>`, so it is naturally excluded by only
/// matching `ReturnStmtSyntax` nodes.
private final class ReduceClosureVisitor: SyntaxVisitor {
    let context: LintContext
    let scopedChildNames: Set<String>
    let actionCaseNames: Set<String>

    init(context: LintContext, scopedChildNames: Set<String>, actionCaseNames: Set<String>) {
        self.context = context
        self.scopedChildNames = scopedChildNames
        self.actionCaseNames = actionCaseNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isReduceCall(node), let closure = trailingClosure(node) else {
            return .visitChildren
        }
        SendDetector(
            context: context,
            scopedChildNames: scopedChildNames,
            actionCaseNames: actionCaseNames,
        ).walk(Syntax(closure.statements))
        // Don't descend further into this call's children via the default walk, since the
        // detector above already covers the closure body. Other arguments (rare) are skipped
        // intentionally to avoid double-reporting.
        return .skipChildren
    }

    private func isReduceCall(_ node: FunctionCallExprSyntax) -> Bool {
        let calleeName = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return calleeName == "Reduce" || calleeName.hasPrefix("Reduce<") || calleeName.hasPrefix("Reduce {")
    }

    private func trailingClosure(_ node: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        if let trailing = node.trailingClosure { return trailing }
        return node.arguments.first?.expression.as(ClosureExprSyntax.self)
    }
}

/// Detects `return .send(.caseName(...))` inside a `Reduce` closure body (at any statement
/// nesting depth, e.g. inside `switch`/`if`), but does not descend into nested closures
/// (such as `.run { send in ... }`), since those are a different effect-returning context.
private final class SendDetector: SyntaxVisitor {
    let context: LintContext
    let scopedChildNames: Set<String>
    let actionCaseNames: Set<String>

    init(context: LintContext, scopedChildNames: Set<String>, actionCaseNames: Set<String>) {
        self.context = context
        self.scopedChildNames = scopedChildNames
        self.actionCaseNames = actionCaseNames
        super.init(viewMode: .sourceAccurate)
    }

    /// Don't descend into nested closures (e.g. `.run { send in ... }`); `return .send(...)`
    /// inside them is not an `Effect` return of the enclosing `Reduce` function and is a
    /// different construct (notifying of an async result via `await send(...)`).
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        guard let expression = node.expression else { return .visitChildren }
        guard let sendCase = sentCaseName(in: expression) else { return .visitChildren }

        guard sendCase != "delegate" else { return .visitChildren }
        guard !scopedChildNames.contains(sendCase) else { return .visitChildren }
        guard actionCaseNames.contains(sendCase) else { return .visitChildren }

        context.report(
            on: node,
            message: "Do not use `return .send(.\(sendCase)(...))` to call another case of the "
                + "same Reducer's `Action` as if it were a function. Mutate `state` directly in "
                + "this action instead, or extract shared logic into a plain function.",
            severity: .error
        )
        return .visitChildren
    }

    /// If `expression` is `.send(.caseName(...))` or `.send(.caseName)`, returns `caseName`.
    /// Returns `nil` for any other shape (including `.send(SomeAction.caseName)`, which this
    /// rule intentionally does not attempt to resolve — false negative is the safe default).
    private func sentCaseName(in expression: ExprSyntaxProtocol) -> String? {
        guard let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
        guard let calledMember = call.calledExpression.as(MemberAccessExprSyntax.self),
              calledMember.declName.baseName.text == "send",
              calledMember.base == nil
        else { return nil }
        guard let sentArgument = call.arguments.first?.expression else { return nil }

        if let memberAccess = sentArgument.as(MemberAccessExprSyntax.self), memberAccess.base == nil {
            return memberAccess.declName.baseName.text
        }
        if let innerCall = sentArgument.as(FunctionCallExprSyntax.self),
           let memberAccess = innerCall.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil
        {
            return memberAccess.declName.baseName.text
        }
        return nil
    }
}
