import SwiftASTLint
import SwiftSyntax

/// Detects a single Swift file that declares both a SwiftUI `View` and a TCA Reducer.
///
/// The TCA architecture convention is to keep a feature's View and its Reducer in separate
/// files (`FooView.swift` / `FooReducer.swift`). Co-locating them in one file couples the UI
/// and the state machine, blurs the boundary the architecture is meant to enforce, and makes
/// the file grow into a hard-to-navigate blob.
///
/// A View is a `struct`/`class` whose inheritance clause contains exactly `View`
/// (token equality, so `ViewModifier` and custom `SomethingView` protocols are excluded, and a
/// type merely *named* `FooView` without conformance is not a View), or an `extension` adding
/// `View` conformance. A Reducer is a type carrying the `@Reducer` attribute, conforming to
/// `Reducer`/`ReducerProtocol`, or an `extension` adding such conformance — matching the
/// detection used by `tca-state-progressive-bool`.
///
/// When a file contains both, a diagnostic is reported on **each** Reducer declaration
/// (deterministic, documented behavior). Files with only Views, or only Reducers — no matter how
/// many, including a parent `@Reducer` with nested `@Reducer enum Destination`/`Path` — are not
/// flagged.
///
/// **Bad** (`FooView.swift`)
/// ```swift
/// struct FooView: View {
///     var body: some View { ... }
/// }
///
/// @Reducer
/// struct FooReducer {
///     // ...
/// }
/// ```
///
/// **Good** — split across two files:
/// ```swift
/// // FooView.swift
/// struct FooView: View {
///     var body: some View { ... }
/// }
/// ```
/// ```swift
/// // FooReducer.swift
/// @Reducer
/// struct FooReducer {
///     // ...
/// }
/// ```
let tcaViewReducerSameFileRule = Rule(id: "tca-view-reducer-same-file") { file, context in
    let visitor = ViewReducerCollector()
    visitor.walk(file)

    // A View only becomes provable after the whole file is walked, so gate here rather than
    // reporting inline. This also makes View-only and Reducer-only files fall out for free.
    guard visitor.fileHasView else { return }

    for position in visitor.reducerNamePositions {
        context.report(
            on: position,
            message: "Declare the View and its Reducer in separate files "
                + "(FooView.swift / FooReducer.swift). A single file must not contain both a "
                + "SwiftUI View and a TCA Reducer.",
            severity: .error
        )
    }
}

/// Single-pass collector that records whether the file declares a View and the position of every
/// Reducer declaration's name token, so the caller can decide after the walk completes.
private final class ViewReducerCollector: SyntaxVisitor {
    private(set) var fileHasView = false
    private(set) var reducerNamePositions: [Syntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if isViewType(inheritance: node.inheritanceClause) {
            fileHasView = true
        }
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause) {
            reducerNamePositions.append(Syntax(node.name))
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if isViewType(inheritance: node.inheritanceClause) {
            fileHasView = true
        }
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause) {
            reducerNamePositions.append(Syntax(node.name))
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause) {
            reducerNamePositions.append(Syntax(node.name))
        }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isViewType(inheritance: node.inheritanceClause) {
            fileHasView = true
        }
        if isReducerType(attributes: node.attributes, inheritance: node.inheritanceClause) {
            reducerNamePositions.append(Syntax(node.extendedType))
        }
        return .visitChildren
    }
}

/// A View is identified by exact `View` token equality in the inheritance clause. Substring
/// matching would wrongly catch `ViewModifier` and custom `SomethingView` protocols, so equality
/// is required.
private func isViewType(inheritance: InheritanceClauseSyntax?) -> Bool {
    guard let inheritance else { return false }
    return inheritance.inheritedTypes.contains { $0.type.trimmedDescription == "View" }
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
