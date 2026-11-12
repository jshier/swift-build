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

func macroEvaluationBenchmarks() {
    Benchmark.withFixture("MacroEvaluation.simpleEvaluationOfLongStrings") {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        let Z = try namespace.declareStringMacro("Z")

        table.push(X, literal: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789")
        table.push(Y, literal: "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ")
        table.push(Z, literal: "!@#$%^&*()_+{}[]\\|;':\",./<>?!@#$%^&*()_+{}[]\\|;':\",./<>?!@#$%^&*()_+{}[]\\|;':\",./<>?!@#$%^&*()_+{}[]\\|;")

        let expr = namespace.parseString("$(X)$(Y)$(Z)$(Y)$(X)$(Y)$(Z)$(Y)$(X)$(X)$(Y)$(Z)$(Y)$(X)$(Y)$(Z)$(Y)$(X)$(X)$(Y)$(Z)$(Y)$(X)$(Y)$(Z)$(Y)$(X)$(X)$(Y)$(Z)$(Y)$(X)$(Y)$(Z)$(Y)$(X)")
        return (scope: MacroEvaluationScope(table: table), expr: expr)
    } _: { benchmark, fixture in
        for _ in 1...10000 {
            blackHole(fixture.scope.evaluate(fixture.expr))
        }
    }

    Benchmark.withFixture("MacroEvaluation.simpleEvaluation") {
        let namespace = MacroNamespace(debugDescription: "test")
        var table = MacroValueAssignmentTable(namespace: namespace)

        let X = try namespace.declareBooleanMacro("X")
        let Y = try namespace.declareBooleanMacro("Y")
        let Z = try namespace.declareBooleanMacro("Z")

        let U = try namespace.declareStringMacro("U")
        let V = try namespace.declareStringMacro("V")
        let W = try namespace.declareStringMacro("W")

        let R = try namespace.declareStringListMacro("R")
        let S = try namespace.declareStringListMacro("S")
        let T = try namespace.declareStringListMacro("T")

        let A = try namespace.declareStringListMacro("A")
        let B = try namespace.declareStringListMacro("B")
        let C = try namespace.declareStringListMacro("C")

        table.push(X, literal: true)
        table.push(Y, literal: false)
        table.push(Z, literal: true || false)
        table.push(U, literal: "0")
        table.push(V, literal: "0123456789")
        table.push(W, literal: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789")
        table.push(R, literal: ["A"])
        table.push(S, literal: ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"])
        table.push(T, literal: [String](repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 26))

        table.push(A, namespace.parseStringList("$(X)$(Y)$(Z)$(U)$(V)$(W)$(R)$(S)$(T)"))
        table.push(B, namespace.parseStringList("$(A)$(A)$(A)$(A)"))
        table.push(C, namespace.parseStringList("$(B)$(B)$(B)$(B)"))

        let expr = namespace.parseString("$(A)$(B)$(C)")
        return (scope: MacroEvaluationScope(table: table), expr: expr)
    } _: { benchmark, fixture in
        for _ in 1...1000 {
            blackHole(fixture.scope.evaluate(fixture.expr))
        }
    }
}
