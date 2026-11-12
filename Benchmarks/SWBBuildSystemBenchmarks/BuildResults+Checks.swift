//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBTestSupport
import SWBUtil

extension BuildOperationTester.BuildResults {
    /// Throws if the build had errors.
    ///
    /// The tester's own checks record issues, which aren't reported outside a test, so benchmarks use this instead.
    func requireNoErrors() throws {
        let errors = getDiagnostics(.error)
        guard errors.isEmpty else {
            throw StubError.error("The build failed:\n\(errors.joined(separator: "\n"))")
        }
    }
}
