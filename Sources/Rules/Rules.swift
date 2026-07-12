import SwiftASTLint
import SwiftSyntax

/// The rule set applied across the entire project.
public let rules = RuleSet {
    tcaBindingAntiPatternRule
    tcaViewStoreSendRule
    tcaNoActionAsFunctionRule
    tcaStateProgressiveBoolRule
    tcaViewReducerSameFileRule
    tcaRunSingleDependencyCallRule
}
