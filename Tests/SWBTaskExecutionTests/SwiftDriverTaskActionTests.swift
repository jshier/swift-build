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

import Testing
import SWBCore
import SWBTaskExecution
import SWBTestSupport

@Suite fileprivate struct SwiftDriverTaskActionTests: CoreBasedTests {
    /// Planning runs detached from the scheduler lanes exactly when the build operation limits detached planning.
    @Test
    func executesDetachedWhenPlanningIsLimited() async throws {
        let core = try await getCore()
        let action = SwiftDriverTaskAction()

        let attached = DynamicTaskOperationContext(core: core, definingTargetsByModuleName: [:], cas: nil, swiftDriverPlanningConcurrency: nil)
        #expect(!action.shouldExecuteDetached(attached))

        let detached = DynamicTaskOperationContext(core: core, definingTargetsByModuleName: [:], cas: nil, swiftDriverPlanningConcurrency: 2)
        #expect(action.shouldExecuteDetached(detached))
    }
}
