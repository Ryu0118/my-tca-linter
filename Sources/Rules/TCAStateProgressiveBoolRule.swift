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

/// ファイル内で`@Reducer`付き、または`Reducer`/`ReducerProtocol`に準拠して宣言された型の名前を集める。
/// `extension Foo { struct State { ... } }` の`Foo`がReducerかどうかを、SwiftSyntaxが行えない
/// 意味論的な型解決に頼らず、同一ファイル内の名前照合だけで判定するために使う。
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

    /// 祖先を遡り、Reducer型（@Reducer付き、またはReducer/ReducerProtocol準拠）の中に
    /// 宣言されたStateかどうかを判定する。extension内の場合は、拡張対象の型名が
    /// ファイル内でReducer型として集められた名前と一致するかで判定する
    /// （extensionはファイルスコープ内で完結する言語仕様上、この名前照合で意味論的に正しい）。
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

    /// `is` + 大文字開始の1語 + `ing` 終わり（isLoading / isEditing / ...）のみを進行形と判定する。
    /// `hasPrefix("is")` と `hasSuffix("ing")` が両立する時点で5文字以上が保証されるため、
    /// 3文字目（index 2）へのアクセスは範囲外にならない。
    private func isProgressiveBoolName(_ name: String) -> Bool {
        guard name.hasPrefix("is"), name.hasSuffix("ing") else { return false }
        let thirdCharacter = name[name.index(name.startIndex, offsetBy: 2)]
        return thirdCharacter.isUppercase
    }

    /// accessorが無い、またはwillSet/didSetのみならstored。get/setを持つならcomputed。
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

    /// 型注釈が `Bool` / `Bool?` / `Optional<Bool>`、または注釈なしでBoolリテラル初期化ならBool型とみなす。
    private func isBoolTyped(_ binding: PatternBindingSyntax) -> Bool {
        if let annotation = binding.typeAnnotation {
            let typeText = annotation.type.trimmedDescription
            return typeText == "Bool" || typeText == "Bool?" || typeText == "Optional<Bool>"
        }
        return binding.initializer?.value.is(BooleanLiteralExprSyntax.self) == true
    }
}
