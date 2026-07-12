import SwiftASTLint
import SwiftSyntax

/// Detects a `.run` effect that performs more than one UseCase/Client call, inside a TCA Reducer.
///
/// A `.run {}` effect should orchestrate a *single* dependency call. Composing several dependency
/// calls (fetch, then track, then sync, ...) inside the Reducer's effect leaks business logic into
/// the Reducer: the composition, its ordering, and its error handling belong in a UseCase that the
/// Reducer calls once. Keeping `.run` down to one call keeps the Reducer a thin dispatcher and makes
/// the composed behavior independently testable.
///
/// A `.run` effect is analyzed only inside types that look like a TCA Reducer (`@Reducer`-attributed,
/// `Reducer`/`ReducerProtocol`-conforming, or an `extension` of such a type declared in the same
/// file — the same detection used by `tca-state-progressive-bool`). A `.run`-like call in an
/// unrelated helper type is out of scope and not flagged.
///
/// A *dependency call site* is a function call whose immediate receiver is an identifier whose name
/// ends with `Client` or `UseCase` (e.g. `userClient.fetch()`, `self.authUseCase.login()`). Calls to
/// `send(...)`, `clock.sleep(...)`, `Task.sleep(...)`, and the `.run` call itself are not dependency
/// calls. Each distinct call expression counts once, so a call inside a `for`/`while` loop or a
/// `for await x in client.stream()` sequence is a single site. Nested closures within the same `.run`
/// (`Result { }`, `withTaskGroup { }`, ...) are inspected, but a nested `.run` is analyzed
/// independently as its own effect.
///
/// When a single `.run` closure contains two or more dependency call sites, a diagnostic is reported
/// on the second and each subsequent site (not on the first, not on the `.run`).
///
/// **Known limitation:** detection is purely name-based on the `Client`/`UseCase` suffix. A
/// dependency that does not follow this naming convention is not detected (a false negative), which
/// is the safe direction — this repo prefers missed detections over false positives.
///
/// **Bad**
/// ```swift
/// return .run { send in
///     let user = try await userClient.fetch()
///     try await analyticsClient.track(user)  // ❌ second dependency call in one .run
/// }
/// ```
///
/// **Good**
/// ```swift
/// return .run { send in
///     // profileUseCase composes the fetch + track internally
///     let user = try await profileUseCase.loadAndTrack()  // ✅ single dependency call
///     await send(.loaded(user))
/// }
/// ```
let tcaRunSingleDependencyCallRule = Rule(id: "tca-run-single-dependency-call") { file, context in
    let reducerTypeNames = ReducerTypeNameCollector.collect(from: file)
    let visitor = RunEffectVisitor(context: context, reducerTypeNames: reducerTypeNames)
    visitor.walk(file)
}

// MARK: - Reducer type name collection

/// Collects the names of types declared in the file that are either `@Reducer`-attributed or
/// conform to `Reducer`/`ReducerProtocol`, so that an `extension Foo { ... }` can be recognized as a
/// Reducer via same-file name matching (extensions are resolved within file scope per the language
/// spec). This mirrors the collector in `tca-state-progressive-bool`.
private enum ReducerTypeNameCollector {
    static func collect(from file: SourceFileSyntax) -> Set<String> {
        let visitor = Visitor()
        visitor.walk(file)
        return visitor.names
    }

    private final class Visitor: SyntaxVisitor {
        var names: Set<String> = []

        init() {
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            collectIfReducer(name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause)
            return .visitChildren
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            collectIfReducer(name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause)
            return .visitChildren
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            collectIfReducer(name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause)
            return .visitChildren
        }

        private func collectIfReducer(
            name: String,
            attributes: AttributeListSyntax,
            inheritance: InheritanceClauseSyntax?
        ) {
            guard isReducerTypeDeclaration(attributes: attributes, inheritance: inheritance) else { return }
            names.insert(name)
        }
    }
}

private func isReducerTypeDeclaration(
    attributes: AttributeListSyntax,
    inheritance: InheritanceClauseSyntax?
) -> Bool {
    if attributes.contains(where: { attribute in
        attribute.as(AttributeSyntax.self)?
            .attributeName.as(IdentifierTypeSyntax.self)?
            .name.text == "Reducer"
    }) {
        return true
    }
    guard let inheritance else { return false }
    return inheritance.inheritedTypes.contains { inherited in
        let name = inherited.type.trimmedDescription
        return name == "Reducer" || name == "ReducerProtocol"
    }
}

// MARK: - Run-effect visitor

/// Walks the file for `.run` / `Effect.run` effect builders that live inside a Reducer type, then
/// counts the dependency call sites in each `.run` closure.
private final class RunEffectVisitor: SyntaxVisitor {
    private let context: LintContext
    private let reducerTypeNames: Set<String>

    init(context: LintContext, reducerTypeNames: Set<String>) {
        self.context = context
        self.reducerTypeNames = reducerTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isRunCall(node),
              let closure = node.trailingClosure,
              isInsideReducer(node)
        else {
            return .visitChildren
        }

        let collector = DependencyCallCollector()
        collector.walk(Syntax(closure.statements))

        // Report on the second and each subsequent dependency call site; the first is allowed.
        for site in collector.callSites.dropFirst() {
            context.report(
                on: site,
                message: "A .run effect should contain a single Client/UseCase call. "
                    + "Compose multiple dependency calls inside a UseCase instead.",
                severity: .error
            )
        }

        // Keep descending: a nested `.run` inside this closure is analyzed independently when the
        // walk reaches it (the collector above skipped its body, so it is not double-counted here).
        return .visitChildren
    }

    /// Matches `.run { ... }` (implicit member) and `Effect.run { ... }`, including a
    /// `.run(priority:) { ... }` form where `priority` is a leading argument and the closure is
    /// trailing.
    private func isRunCall(_ node: FunctionCallExprSyntax) -> Bool {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "run"
        else { return false }
        guard let base = member.base else { return true }
        return base.as(DeclReferenceExprSyntax.self)?.baseName.text == "Effect"
    }

    /// Walks ancestors to determine whether this `.run` call is inside a Reducer type: a
    /// `@Reducer`/conformance type declaration, or an `extension` of a type collected as a Reducer
    /// within the same file.
    private func isInsideReducer(_ node: FunctionCallExprSyntax) -> Bool {
        var current = node.parent
        while let syntax = current {
            if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
                if reducerTypeNames.contains(extensionDecl.extendedType.trimmedDescription) {
                    return true
                }
            } else if let group = syntax.asProtocol(DeclGroupSyntax.self) {
                if isReducerTypeDeclaration(attributes: group.attributes, inheritance: group.inheritanceClause) {
                    return true
                }
            }
            current = syntax.parent
        }
        return false
    }
}

// MARK: - Dependency call site collector

/// Collects dependency call sites within a single `.run` closure body, in source order. Descends
/// into nested closures (`Result { }`, `withTaskGroup { }`, loop bodies) so calls composed there are
/// counted, but stops at a nested `.run` call so that each `.run` is analyzed independently.
private final class DependencyCallCollector: SyntaxVisitor {
    private(set) var callSites: [FunctionCallExprSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // A nested `.run` / `Effect.run` is its own effect: don't count it and don't descend into
        // it; the outer `RunEffectVisitor` walk analyzes it independently.
        if isRunCall(node) {
            return .skipChildren
        }
        if isDependencyCall(node) {
            callSites.append(node)
        }
        return .visitChildren
    }

    private func isRunCall(_ node: FunctionCallExprSyntax) -> Bool {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "run"
        else { return false }
        guard let base = member.base else { return true }
        return base.as(DeclReferenceExprSyntax.self)?.baseName.text == "Effect"
    }

    /// A dependency call is a member-access call (`receiver.method(...)`) whose immediate receiver is
    /// an identifier (or the trailing member of a chain) whose name ends with `Client` or `UseCase`.
    /// `self.userClient.fetch()` → receiver `userClient`. `self.userClient.session.fetch()` →
    /// receiver `session`, not counted.
    private func isDependencyCall(_ node: FunctionCallExprSyntax) -> Bool {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              let base = member.base,
              let receiverName = trailingIdentifier(of: base)
        else { return false }
        return receiverName.hasSuffix("Client") || receiverName.hasSuffix("UseCase")
    }

    /// Returns the trailing identifier of a receiver expression: `userClient` → `userClient`,
    /// `self.userClient` → `userClient`, `a.b.c` → `c`. Returns `nil` for shapes with no identifier
    /// (e.g. a function call receiver like `factory().client`).
    private func trailingIdentifier(of expr: ExprSyntax) -> String? {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}
