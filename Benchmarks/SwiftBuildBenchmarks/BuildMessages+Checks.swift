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

import SwiftBuild
import SWBUtil

extension Array where Element == SwiftBuildMessage {
    /// Throws if the build had errors.
    ///
    /// The testers' own checks record issues, which aren't reported outside a test, so benchmarks use this instead.
    func requireNoErrors() throws {
        let errors = compactMap { event -> String? in
            guard case let .diagnostic(diagnostic) = event, diagnostic.kind == .error else { return nil }
            return diagnostic.message
        }
        guard errors.isEmpty else {
            throw StubError.error("The build failed:\n\(errors.joined(separator: "\n"))")
        }
    }

    /// The number of targets that were up to date.
    var upToDateTargetCount: Int {
        count { event in
            if case .targetUpToDate = event { true } else { false }
        }
    }
}
