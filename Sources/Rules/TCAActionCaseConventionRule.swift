import SwiftASTLint
import SwiftSyntax

/// Arguments for ``tcaActionCaseConventionRule``.
struct TCAActionCaseConventionArguments: Codable, Sendable {
    /// Case names that stand for the three action categories. A case with one of these names and
    /// exactly one associated value is always allowed. Rename these to match a project that spells
    /// the internal category differently (`internal` instead of `internalAction`, for example).
    var categoryCaseNames: [String]
    /// Extra case names allowed on top of the categories. Escape hatch for project-specific
    /// exceptions that cannot be expressed by a payload type.
    var additionalAllowedCaseNames: [String]

    init(
        categoryCaseNames: [String] = ["view", "internalAction", "delegate"],
        additionalAllowedCaseNames: [String] = []
    ) {
        self.categoryCaseNames = categoryCaseNames
        self.additionalAllowedCaseNames = additionalAllowedCaseNames
    }

    enum CodingKeys: String, CodingKey {
        case categoryCaseNames = "category_case_names"
        case additionalAllowedCaseNames = "additional_allowed_case_names"
    }

    /// Decodes each key independently so that a YAML file overriding only one argument keeps the
    /// defaults for the others (the synthesized `Decodable` would require every key to be present).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        categoryCaseNames = try container.decodeIfPresent([String].self, forKey: .categoryCaseNames)
            ?? defaults.categoryCaseNames
        additionalAllowedCaseNames = try container
            .decodeIfPresent([String].self, forKey: .additionalAllowedCaseNames)
            ?? defaults.additionalAllowedCaseNames
    }
}

/// Detects cases in a root Reducer `Action` enum that are neither one of the three action
/// categories, nor a child Reducer scope, nor the `BindableAction` binding requirement.
///
/// A root `Action` is meant to be a router, not a place to put domain events. Every event belongs
/// to one of three categories — `view` (user intent), `internalAction` (effect results and other
/// self-directed events) and `delegate` (notifications to the parent) — each declared in its own
/// nested enum. Anything else declared directly on `Action` breaks that split and makes the action
/// log ambiguous about who sent what.
///
/// A case is allowed when any of the following holds:
///
/// 1. **Category** — the case name is one of `category_case_names`
///    (default `view` / `internalAction` / `delegate`) and it has exactly one associated value.
/// 2. **Child Reducer scope** — its single associated value is a `Foo.Action`, an
///    `IdentifiedAction<…>` / `IdentifiedActionOf<…>`, or a `StackAction<…>` / `StackActionOf<…>`.
/// 3. **Presentation** — its single associated value is a `PresentationAction<…>`. Both
///    `PresentationAction<Destination.Action>` (a scoped child Reducer) and
///    `PresentationAction<Alert>` (a plain, non-Reducer enum driving `.ifLet(\.$alert, action:)`)
///    are legitimate, so the wrapped type is deliberately not inspected.
/// 4. **Binding** — its single associated value is a `BindingAction<…>`. `BindableAction` requires
///    this case to live on the root `Action`, so it cannot be moved into a category enum.
///
/// A case with **no** associated value, or with **more than one**, is always a violation: neither
/// shape can be a scope, a presentation or a binding.
///
/// The rule only inspects an enum literally named `Action` whose immediate enclosing declaration
/// is a Reducer (`@Reducer`-attributed, `Reducer`/`ReducerProtocol`-conforming) or a Reducer
/// extension. The nested `ViewAction` / `InternalAction` / `DelegateAction` enums,
/// `Action` enums in helper types nested inside a Reducer, `@Reducer enum Destination`-style enum
/// Reducers, and any `Action` enum outside a Reducer are left alone.
///
/// **Bad**
/// ```swift
/// enum Action: ViewAction, Sendable {
///     case view(ViewAction)
///     case fetchResponse(Result<[Item], any Error>)    // ❌ belongs in InternalAction
///     case dismiss                                     // ❌ belongs in ViewAction or DelegateAction
///     case presentAlert(title: String, message: String) // ❌
/// }
/// ```
///
/// **Good**
/// ```swift
/// enum Action: BindableAction, ViewAction, Sendable {
///     case view(ViewAction)
///     case internalAction(InternalAction)
///     case delegate(DelegateAction)
///     case child(ChildReducer.Action)
///     case path(StackActionOf<Path>)
///     case alert(PresentationAction<Alert>)
///     case binding(BindingAction<State>)
/// }
/// ```
///
/// - Note: The rule errs towards missing violations rather than reporting false positives, because
///   it only ever sees type *names*, never resolved types. Concretely, it does not verify that the
///   payload of a category case is the matching `ViewAction` / `InternalAction` / `DelegateAction`
///   type (a custom payload type is accepted), it does not inspect what a `PresentationAction` or
///   an `IdentifiedAction` wraps, and it treats a single-value case whose payload merely *ends in*
///   `.Action` as a scope even if no such child Reducer exists.
let tcaActionCaseConventionRule = ParameterizedRule(
    id: "tca-action-case-convention",
    defaultArguments: TCAActionCaseConventionArguments()
) { file, context, arguments in
    let reducerTypeNames = ReducerTypeNameCollector.collect(from: file)
    let visitor = ActionCaseConventionVisitor(
        context: context,
        reducerTypeNames: reducerTypeNames,
        categoryCaseNames: Set(arguments.categoryCaseNames),
        additionalAllowedCaseNames: Set(arguments.additionalAllowedCaseNames)
    )
    visitor.walk(file)
}

/// Type names whose generic form is always a legitimate composition point on a root `Action`.
private let scopeGenericTypeNames: Set<String> = [
    "IdentifiedAction",
    "IdentifiedActionOf",
    "StackAction",
    "StackActionOf",
    "PresentationAction",
    "BindingAction",
]

/// Collects the names of types declared in the file that are either `@Reducer`-attributed or
/// conform to `Reducer`/`ReducerProtocol`.
/// Used to determine whether the `Foo` in `extension Foo { enum Action { ... } }` is a Reducer via
/// name matching within the same file, rather than relying on semantic type resolution, which
/// SwiftSyntax cannot perform. An extension that declares the conformance itself is handled
/// directly by ``ActionCaseConventionVisitor``.
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

private let reducerConformanceNames: Set<String> = [
    "Reducer",
    "ReducerProtocol",
    "ComposableArchitecture.Reducer",
    "ComposableArchitecture.ReducerProtocol",
]

private func isReducerTypeDeclaration(
    attributes: AttributeListSyntax,
    inheritance: InheritanceClauseSyntax?
) -> Bool {
    if hasReducerAttribute(attributes) {
        return true
    }
    guard let inheritance else { return false }
    return inheritance.inheritedTypes.contains { inherited in
        reducerConformanceNames.contains(inherited.type.trimmedDescription)
    }
}

private func hasReducerAttribute(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { attribute in
        guard let name = attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription else {
            return false
        }
        return name == "Reducer" || name == "ComposableArchitecture.Reducer"
    }
}

private final class ActionCaseConventionVisitor: SyntaxVisitor {
    private let context: LintContext
    private let reducerTypeNames: Set<String>
    private let categoryCaseNames: Set<String>
    private let additionalAllowedCaseNames: Set<String>

    init(
        context: LintContext,
        reducerTypeNames: Set<String>,
        categoryCaseNames: Set<String>,
        additionalAllowedCaseNames: Set<String>
    ) {
        self.context = context
        self.reducerTypeNames = reducerTypeNames
        self.categoryCaseNames = categoryCaseNames
        self.additionalAllowedCaseNames = additionalAllowedCaseNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "Action", isRootAction(node) else { return .visitChildren }
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                check(element)
            }
        }
        return .visitChildren
    }

    /// Returns true only when the first enclosing declaration is a Reducer type or a Reducer
    /// extension. Stopping at that first declaration prevents an unrelated helper's `Action` from
    /// being mistaken for the outer Reducer's root `Action`.
    private func isRootAction(_ node: EnumDeclSyntax) -> Bool {
        var current = node.parent
        while let syntax = current {
            if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
                return isReducerExtension(extensionDecl)
            } else if let group = syntax.asProtocol(DeclGroupSyntax.self) {
                return isReducerTypeDeclaration(attributes: group.attributes, inheritance: group.inheritanceClause)
            }
            current = syntax.parent
        }
        return false
    }

    /// Recognizes both an extension of a Reducer declared in the same file and an extension that
    /// adds the Reducer conformance itself.
    private func isReducerExtension(_ node: ExtensionDeclSyntax) -> Bool {
        reducerTypeNames.contains(node.extendedType.trimmedDescription)
            || isReducerTypeDeclaration(attributes: node.attributes, inheritance: node.inheritanceClause)
    }

    private func check(_ element: EnumCaseElementSyntax) {
        let name = unescapedName(element.name.text)
        // The escape hatch is unconditional: a project-specific exception may have any shape.
        if additionalAllowedCaseNames.contains(name) { return }
        guard let parameters = element.parameterClause?.parameters, parameters.count == 1 else {
            report(element, name: name, reason: parameterCountReason(element))
            return
        }
        if categoryCaseNames.contains(name) { return }
        guard let type = parameters.first?.type else { return }
        if isComposableActionType(type) { return }
        report(
            element,
            name: name,
            reason: "its associated value `\(type.trimmedDescription)` is not a child Reducer action, "
                + "a `PresentationAction` or a `BindingAction`"
        )
    }

    /// Strips the backticks from a keyword-escaped case name (`` case `internal` ``) so that the
    /// configured names can be written without them.
    private func unescapedName(_ text: String) -> String {
        guard text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 else { return text }
        return String(text.dropFirst().dropLast())
    }

    private func parameterCountReason(_ element: EnumCaseElementSyntax) -> String {
        let count = element.parameterClause?.parameters.count ?? 0
        if count == 0 {
            return "it has no associated value, so it can only be a domain event"
        }
        return "it has \(count) associated values, so it cannot be a category, a scope or a binding"
    }

    /// Returns true when the payload can only be an action routed to somewhere else: a child
    /// Reducer's `Action`, or one of the composition wrappers in ``scopeGenericTypeNames``.
    private func isComposableActionType(_ type: TypeSyntax) -> Bool {
        let unwrapped = unwrapOptional(type)
        if let member = unwrapped.as(MemberTypeSyntax.self) {
            if member.name.text == "Action" {
                return true
            }
            return scopeGenericTypeNames.contains(member.name.text) && member.genericArgumentClause != nil
        }
        if let identifier = unwrapped.as(IdentifierTypeSyntax.self) {
            return scopeGenericTypeNames.contains(identifier.name.text) && identifier.genericArgumentClause != nil
        }
        return false
    }

    private func unwrapOptional(_ type: TypeSyntax) -> TypeSyntax {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return unwrapOptional(optional.wrappedType)
        }
        return type
    }

    private func report(_ element: EnumCaseElementSyntax, name: String, reason: String) {
        context.report(
            on: element,
            message: "`case \(name)` is not allowed on a root Reducer `Action` because \(reason). "
                + "Move it into the nested `ViewAction` (user intent), `InternalAction` (effect "
                + "results) or `DelegateAction` (notifications to the parent) enum.",
            severity: .error
        )
    }
}
