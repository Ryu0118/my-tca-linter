import SwiftASTLint
import SwiftSyntax

/// Detects stored progressive-form Bool flags (`isLoading`, `isSubmitting`, ...) declared
/// in a TCA Reducer `State`.
///
/// A stored `isXXXing` Bool collapses one phase of a state machine into an independent flag,
/// allowing illegal combinations such as `isLoading && isError`. Model the phase with an enum
/// (`LoadStatus` / `DataState` / `PagingDataState`, or a feature-local `Phase` / `Step` / `Mode`)
/// and expose a computed projection if the View needs a Bool.
///
/// A `State` is identified by the `@ObservableState` attribute, or by the struct name `State`
/// nested inside a Reducer type (`@Reducer`-attributed, `Reducer`/`ReducerProtocol`-conforming,
/// or an `extension` of one of those types declared in the same file). Computed properties,
/// `let` constants, `static` members, non-Bool types, and non-progressive names
/// (`isAllDay`, `isPublic`, ...) are not flagged.
///
/// **Bad**
/// ```swift
/// struct State {
///     var isLoading = false
/// }
/// ```
///
/// **Good**
/// ```swift
/// struct State {
///     var status: LoadStatus<Profile> = .idle
///     var isLoading: Bool { status.isLoading }  // computed projection is fine
/// }
/// ```
let tcaStateProgressiveBoolRule = Rule(id: "tca-state-progressive-bool") { file, context in
    let reducerTypeNames = ReducerTypeNameCollector.collect(from: file)
    let visitor = StateProgressiveBoolVisitor(context: context, reducerTypeNames: reducerTypeNames)
    visitor.walk(file)
}

/// Collects the names of types declared in the file that are either `@Reducer`-attributed or
/// conform to `Reducer`/`ReducerProtocol`.
/// Used to determine whether the `Foo` in `extension Foo { struct State { ... } }` is a Reducer
/// via name matching within the same file, rather than relying on semantic type resolution,
/// which SwiftSyntax cannot perform.
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
            guard isReducerType(attributes: attributes, inheritance: inheritance) else { return }
            names.insert(name)
        }
    }
}

private func isReducerType(
    attributes: AttributeListSyntax,
    inheritance: InheritanceClauseSyntax?
) -> Bool {
    if hasAttribute(attributes, named: "Reducer") {
        return true
    }
    guard let inheritance else { return false }
    return inheritance.inheritedTypes.contains { inherited in
        let name = inherited.type.trimmedDescription
        return name == "Reducer" || name == "ReducerProtocol"
    }
}

private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
    attributes.contains { attribute in
        attribute.as(AttributeSyntax.self)?
            .attributeName.as(IdentifierTypeSyntax.self)?
            .name.text == name
    }
}

private final class StateProgressiveBoolVisitor: SyntaxVisitor {
    private let context: LintContext
    private let reducerTypeNames: Set<String>

    init(context: LintContext, reducerTypeNames: Set<String>) {
        self.context = context
        self.reducerTypeNames = reducerTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isReducerState(node) else { return .visitChildren }
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            check(varDecl)
        }
        return .visitChildren
    }

    private func isReducerState(_ node: StructDeclSyntax) -> Bool {
        if hasAttribute(node.attributes, named: "ObservableState") {
            return true
        }
        guard node.name.text == "State" else { return false }
        return isNestedInReducer(node)
    }

    /// Walks up the ancestors to determine whether this `State` is declared inside a Reducer
    /// type (`@Reducer`-attributed, or conforming to `Reducer`/`ReducerProtocol`). When declared
    /// inside an extension, this is determined by matching the extended type's name against the
    /// set of names collected as Reducer types within the file (this name matching is
    /// semantically correct because extensions are resolved within file scope per the language
    /// spec).
    private func isNestedInReducer(_ node: StructDeclSyntax) -> Bool {
        var current = node.parent
        while let syntax = current {
            if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
                let extendedTypeName = extensionDecl.extendedType.trimmedDescription
                if reducerTypeNames.contains(extendedTypeName) {
                    return true
                }
            } else if let group = syntax.asProtocol(DeclGroupSyntax.self) {
                if isReducerType(attributes: group.attributes, inheritance: group.inheritanceClause) {
                    return true
                }
            }
            current = syntax.parent
        }
        return false
    }

    private func check(_ varDecl: VariableDeclSyntax) {
        guard varDecl.bindingSpecifier.tokenKind == .keyword(.var),
              !varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
        else { return }

        for binding in varDecl.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  isProgressiveBoolName(identifier),
                  isStored(binding),
                  isBoolTyped(binding)
            else { continue }

            context.report(
                on: binding,
                message: "Do not model an in-progress state as a stored Bool (`\(identifier)`) in Reducer State. "
                    + "Represent the phase with an enum (`LoadStatus` / `DataState` / `PagingDataState`, "
                    + "or a feature-local `Phase` / `Step` / `Mode`) "
                    + "and expose `var \(identifier): Bool { ... }` as a computed projection if the View needs it.",
                severity: .error
            )
        }
    }

    /// Treats only `is` + a capitalized word + `ing` suffix (isLoading / isEditing / ...) as
    /// progressive form. Once both `hasPrefix("is")` and `hasSuffix("ing")` hold, the string is
    /// guaranteed to be at least 5 characters long, so accessing the third character (index 2)
    /// never goes out of bounds.
    private func isProgressiveBoolName(_ name: String) -> Bool {
        guard name.hasPrefix("is"), name.hasSuffix("ing") else { return false }
        let thirdCharacter = name[name.index(name.startIndex, offsetBy: 2)]
        return thirdCharacter.isUppercase
    }

    /// Stored if there is no accessor, or only willSet/didSet. Computed if it has a getter.
    private func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else { return true }
        switch accessorBlock.accessors {
        case .getter:
            return false
        case let .accessors(accessorList):
            return accessorList.allSatisfy { accessor in
                accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                    || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
            }
        }
    }

    /// Considered Bool-typed if the type annotation is `Bool` / `Bool?` / `Optional<Bool>`, or if
    /// there is no annotation but the initializer is a Bool literal.
    private func isBoolTyped(_ binding: PatternBindingSyntax) -> Bool {
        if let annotation = binding.typeAnnotation {
            let typeText = annotation.type.trimmedDescription
            return typeText == "Bool" || typeText == "Bool?" || typeText == "Optional<Bool>"
        }
        return binding.initializer?.value.is(BooleanLiteralExprSyntax.self) == true
    }
}
