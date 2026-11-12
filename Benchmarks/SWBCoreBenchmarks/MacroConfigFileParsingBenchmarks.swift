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
import SWBMacro
import SWBUtil

/// Registers a benchmark that parses the contents that `makeContents` returns `iterations` times.
private func parsingBenchmark(_ name: String, iterations: Int, _ makeContents: @escaping () -> ByteString) {
    Benchmark.withFixture("MacroConfigFileParsing.\(name)") {
        makeContents()
    } _: { benchmark, contents in
        for _ in 1...iterations {
            let parser = MacroConfigFileParser(byteString: contents, path: Path("runParsingTest().xcconfig"), delegate: nil)
            parser.parse()
            blackHole(parser)
        }
    }
}

func macroConfigFileParsingBenchmarks() {
    parsingBenchmark("parsingOfEmptyStrings_X100000", iterations: 100000) {
        ""
    }

    parsingBenchmark("parsingOfSingleSimpleAssignments_X100000", iterations: 100000) {
        "MACRO=VALUE"
    }

    parsingBenchmark("parsingOfMultipleSimpleAssignments_X1000", iterations: 1000) {
        ByteString(encodingAsUTF8: [String](repeating: "MACRO=VALUE", count: 10).joined(separator: "\n"))
    }

    parsingBenchmark("parsing1MBFile_X10", iterations: 10) {
        ByteString(encodingAsUTF8: (0..<44616).map { "MACRO\($0) = VALUE\($0)" }.joined(separator: "\n"))
    }
}
