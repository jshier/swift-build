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

import Synchronization

/// A thread-safe dictionary for values which are read and written from many threads at once, such as caches used during concurrent work.
///
/// Unlike `Registry`, which has a single lock, the keys are divided among several independently locked shards, so that concurrent accesses rarely contend. Values are computed outside of the lock, so concurrent callers may compute the value for a key more than once, but they all receive the first value stored.
public final class ShardedRegistry<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private final class Shard: Sendable {
        let values = SWBMutex<[Key: Value]>([:])
        // Keep each shard's lock on its own cache line, so that accessing one shard doesn't slow down accesses to another.
        private let padding: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private let shards: [Shard]

    /// - parameter shardCount: The number of shards, which should be about the number of threads accessing the registry at once.
    public init(shardCount: Int = 32) {
        precondition(shardCount > 0)
        shards = (0..<shardCount).map { _ in Shard() }
    }

    private func shard(for key: Key) -> Shard {
        shards[Int(UInt(bitPattern: key.hashValue) % UInt(shards.count))]
    }

    public subscript(_ key: Key) -> Value? {
        shard(for: key).values.withLock { $0[key] }
    }

    /// Returns the value for the key, computing and storing it if there isn't one.
    public func getOrInsert(_ key: Key, _ compute: () throws -> Value) rethrows -> Value {
        let shard = shard(for: key)
        if let value = shard.values.withLock({ $0[key] }) {
            return value
        }
        let value = try compute()
        return shard.values.withLock { values in
            if let existing = values[key] {
                return existing
            }
            values[key] = value
            return value
        }
    }

    public func removeAll() {
        for shard in shards {
            shard.values.withLock { $0.removeAll() }
        }
    }
}
