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

public import Synchronization

/// A thread-safe dictionary for values that many threads read and write at once, such as caches for concurrent work.
///
/// Unlike `Registry`, which has a single lock, keys are divided among independently locked shards, so concurrent
/// accesses rarely contend. Values are computed outside the lock, so concurrent callers may compute a key's value more
/// than once, but all of them receive the first value stored.
public final class ShardedRegistry<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    @usableFromInline final class Shard: Sendable {
        @usableFromInline let values = SWBMutex<[Key: Value]>([:])
        // Pad each shard to more than 128 bytes, so no two shards' locks share a cache line, which is 128 bytes on Apple
        // silicon, and 64 bytes on Intel (whose prefetcher fetches lines in 128-byte pairs) and most other arm64 cores.
        private let padding: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    @usableFromInline let shards: [Shard]

    /// - parameter shardCount: The number of shards, about the number of threads expected to access the registry at
    ///   once.
    public init(shardCount: Int = 32) {
        precondition(shardCount > 0)
        shards = (0..<shardCount).map { _ in Shard() }
    }

    @inlinable
    func shard(for key: Key) -> Shard {
        shards[Int(UInt(bitPattern: key.hashValue) % UInt(shards.count))]
    }

    @inlinable
    public subscript(_ key: Key) -> Value? {
        shard(for: key).values.withLock { $0[key] }
    }

    /// Returns the value for the key, computing and storing it if there isn't one.
    ///
    /// Inlinable so that clients specialize it. Unspecialized, each call looks up the dictionary's generic metadata at
    /// runtime, which takes a runtime lock that threads contend on.
    @inlinable
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
