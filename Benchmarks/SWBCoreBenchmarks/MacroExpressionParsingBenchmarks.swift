//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Benchmark
import SWBBenchmarkSupport
@_spi(Testing) import SWBCore
import SWBMacro
import SWBTestSupport
import SWBUtil
import Testing

private final class MockMacroExpressionParserDelegate: MacroExpressionParserDelegate {
    func foundLiteralStringFragment(_ string: Input, parser: MacroExpressionParser) {}
    func foundStringFormOnlyLiteralStringFragment(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {}
    func foundStartOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {}
    func foundStartOfMacroName(parser: MacroExpressionParser) {}
    func foundEndOfMacroName(wasBracketed: Bool, parser: MacroExpressionParser) {}
    func foundRetrievalOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundStartOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundEndOfReplacementOperator(_ operatorName: Input, parser: MacroExpressionParser) {}
    func foundEndOfSubstitutionSubexpression(alwaysEvalAsString: Bool, parser: MacroExpressionParser) {}
    func foundListElementSeparator(_ string: MacroExpressionParserDelegate.Input, parser: MacroExpressionParser) {}
    func handleDiagnostic(_ diagnostic: MacroExpressionDiagnostic, parser: MacroExpressionParser) {}
}

private func parse(_ string: String) {
    let parser = MacroExpressionParser(string: string, delegate: MockMacroExpressionParserDelegate())
    parser.parseAsString()
    blackHole(parser)
}

/// Registers a benchmark that parses `string` `iterations` times.
private func stringParsingBenchmark(_ name: String, _ string: String, iterations: Int) {
    Benchmark("MacroExpressionParsing.\(name)") { (benchmark: Benchmark) in
        for _ in 1...iterations {
            parse(string)
        }
    }
}

/// The macro expressions of the command line templates of every build option of the core's property domain specs.
private func commandLineTemplateExpressions() async throws -> [String] {
    let core = try await TestingCore().getCore()

    var propertyDomainSpecs = [PropertyDomainSpec]()
    for domainRegistry in core.specRegistry.proxiesByDomain.values {
        for specProxy in domainRegistry.proxiesByIdentifier.values {
            if let spec = specProxy.load(core.specRegistry) as? PropertyDomainSpec {
                propertyDomainSpecs.append(spec)
            }
        }
    }

    func expressions(_ spec: BuildOptionValue.CommandLineTemplateSpecifier) -> [String] {
        switch spec {
        case .empty: return []
        case .literal: return ["$(value)"]
        case .args(let exprs): return [exprs.stringRep]
        case .flag(let str): return [str.stringRep, "$(value)"]
        case .prefixFlag(let str): return [str.stringRep + "$(value)"]
        }
    }

    var result = [String]()
    for spec in propertyDomainSpecs {
        for buildOption in spec.buildOptions {
            if let template = buildOption.emptyValueDefn?.commandLineTemplate {
                result += expressions(template)
            }
            if let template = buildOption.otherValueDefn?.commandLineTemplate {
                result += expressions(template)
            }
            if let values = buildOption.valueDefns?.values {
                for value in values {
                    if let template = value.commandLineTemplate {
                        result += expressions(template)
                    }
                }
            }
        }
    }
    guard !result.isEmpty else {
        throw StubError.error("the specs have no command line templates")
    }
    return result
}

func macroExpressionParsingBenchmarks() {
    stringParsingBenchmark("parsingOfEmptyStrings_X10000", "", iterations: 10000)
    stringParsingBenchmark("parsingOfShortLiteralStrings_X10000", "A short string.", iterations: 10000)
    stringParsingBenchmark("parsingOfLongLiteralStrings_X10000", "A long (or at least somewhat long, or perhaps maybe even a little longer) string without any particularly interesting characters (other than, perhaps, parentheses) in it.", iterations: 10000)
    stringParsingBenchmark("parsingOfSimpleMacroExpressions_X10000", "$(X)$(Y)$(Z)$($(X)$(Y)$(Z))", iterations: 10000)

    Benchmark.withFixture("MacroExpressionParsing.parsingAllSpecMacrosPerf") {
        try await commandLineTemplateExpressions()
    } _: { benchmark, expressions in
        for expression in expressions {
            parse(expression)
        }
    }
}
