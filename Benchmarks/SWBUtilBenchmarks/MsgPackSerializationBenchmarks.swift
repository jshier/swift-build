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
import SWBUtil

/// Benchmarks for the MsgPackSerializer class.
///
/// These benchmarks are not intended to compare the performance of serializing individual types of elements (there are many different breakdowns we should consider if we want to do that), but to provide a baseline for future performance improvement to the serializer.
func msgPackSerializationBenchmarks() {
    Benchmark("MsgPackSerialization.serializingScalar_13Elements_X100000") { (benchmark: Benchmark) in
        for _ in 1...100000 {
            blackHole(serializeScalarData().byteString)
        }
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingScalar_13Elements_X100000") {
        serializeScalarData()
    } _: { benchmark, sz in
        for _ in 1...100000 {
            let dsz = MsgPackDeserializer(sz.byteString)
            blackHole(try dsz.deserialize() as Int)
            blackHole(try dsz.deserialize() as Int)
            blackHole(try dsz.deserialize() as Int)
            blackHole(try dsz.deserialize() as UInt)
            blackHole(try dsz.deserialize() as UInt)
            blackHole(try dsz.deserialize() as Bool)
            blackHole(try dsz.deserialize() as Bool)
            blackHole(try dsz.deserialize() as Float32)
            blackHole(try dsz.deserialize() as Float32)
            blackHole(try dsz.deserialize() as Float32)
            blackHole(try dsz.deserialize() as Float64)
            blackHole(try dsz.deserialize() as Float64)
            blackHole(try dsz.deserialize() as Float64)
        }
    }

    Benchmark("MsgPackSerialization.serializingString_5Elements_X100000") { (benchmark: Benchmark) in
        for _ in 1...100000 {
            blackHole(serializeStringData().byteString)
        }
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingString_5Elements_X100000") {
        serializeStringData()
    } _: { benchmark, sz in
        for _ in 1...100000 {
            let dsz = MsgPackDeserializer(sz.byteString)
            for _ in 0..<5 {
                blackHole(try dsz.deserialize() as String)
            }
        }
    }

    Benchmark("MsgPackSerialization.serializingArray_5X5Elements_X100000") { (benchmark: Benchmark) in
        for _ in 1...100000 {
            blackHole(serializeArrayData().byteString)
        }
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingArray_5X5Elements_X100000") {
        serializeArrayData()
    } _: { benchmark, sz in
        for _ in 1...100000 {
            let dsz = MsgPackDeserializer(sz.byteString)
            blackHole(try dsz.deserialize() as [Int])
            blackHole(try dsz.deserialize() as [UInt])
            blackHole(try dsz.deserialize() as [Bool])
            blackHole(try dsz.deserialize() as [Float32])
            blackHole(try dsz.deserialize() as [Float64])
            blackHole(try dsz.deserialize() as [String])
        }
    }

    Benchmark("MsgPackSerialization.serializingDictionary_2X3Elements_X100000") { (benchmark: Benchmark) in
        for _ in 1...100000 {
            blackHole(serializeDictionaryData().byteString)
        }
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingDictionary_2X3Elements_X100000") {
        serializeDictionaryData()
    } _: { benchmark, sz in
        for _ in 1...100000 {
            let dsz = MsgPackDeserializer(sz.byteString)
            blackHole(try dsz.deserialize() as [String: Int])
            blackHole(try dsz.deserialize() as [Float32: Bool])
        }
    }

    Benchmark.withFixture("MsgPackSerialization.serializingCustomElement_100Elements_X10000") {
        customElementData()
    } _: { benchmark, elements in
        for _ in 1...10000 {
            blackHole(serializeCustomElementData(elements).byteString)
        }
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingCustomElement_100Elements_X10000") {
        let elements = customElementData()
        return (elements.count, serializeCustomElementData(elements))
    } _: { benchmark, setup in
        let (elementCount, sz) = setup
        for _ in 1...10000 {
            let dsz = MsgPackDeserializer(sz.byteString)
            for _ in 0..<elementCount {
                blackHole(try dsz.deserialize() as TestLogMessage)
            }
        }
    }

    Benchmark.withFixture("MsgPackSerialization.serializingCustomElementHierarchy_100X100X100Elements_X1", configuration: .swiftBuild(maxIterations: 10)) {
        customElementHierarchy(100)
    } _: { benchmark, log in
        blackHole(serializeCustomElementHierarchy(log))
    }

    Benchmark.withFixture("MsgPackSerialization.deserializingCustomElementHierarchy_100X100X100Elements_X1", configuration: .swiftBuild(maxIterations: 10)) {
        serializeCustomElementHierarchy(customElementHierarchy(100))
    } _: { benchmark, sz in
        let dsz = MsgPackDeserializer(sz.byteString)
        blackHole(try dsz.deserialize() as TestLogHeader)
    }
}

private func serializeScalarData() -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    sz.serialize(3 as Int)
    sz.serialize(0 as Int)
    sz.serialize(-3 as Int)
    sz.serialize(0 as UInt)
    sz.serialize(7 as UInt)
    sz.serialize(true)
    sz.serialize(false)
    sz.serialize(-5.3 as Float32)
    sz.serialize(0.0 as Float32)
    sz.serialize(2.47 as Float32)
    sz.serialize(-7.9 as Float64)
    sz.serialize(0.0 as Float64)
    sz.serialize(5.44 as Float64)
    return sz
}

private func serializeStringData() -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    sz.serialize("foo")
    sz.serialize("bar")
    sz.serialize("baz")
    sz.serialize("quux")
    sz.serialize("")
    return sz
}

private func serializeArrayData() -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    sz.serialize([-2, -1, 0, 1, 2] as [Int])
    sz.serialize([0, 1, 2, 3, 4] as [UInt])
    sz.serialize([false, true, true, false, true])
    sz.serialize([-2.3, -1.1, 0.0, 0.7, 1.8] as [Float32])
    sz.serialize([-1.93, -0.98, 0.0, 1.13, 2.41] as [Float64])
    sz.serialize(["foo", "bar", "baz", "quux", "nul"])
    return sz
}

private func serializeDictionaryData() -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    sz.serialize(["minusone": -1, "zero": 0, "one": 1] as [String: Int])
    sz.serialize([-1.3: false, 0.0: true, 1.2: false] as [Float32: Bool])
    return sz
}

private func customElementData() -> [TestLogMessage] {
    var elements = [TestLogMessage]()
    for i in 1...100 {
        let element = TestLogMessage(type: .error, message: "error: Message #\(i)")
        elements.append(element)
    }
    return elements
}

private func serializeCustomElementData(_ elements: [TestLogMessage]) -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    for element in elements {
        sz.serialize(element)
    }
    return sz
}

private func customElementHierarchy(_ numElements: UInt) -> TestLogHeader {
    // The top-level log element.
    let log = TestLogHeader("Log")

    // Add 100 framework targets, each with 100 source file compilations, each of which emits 100 warnings.
    for i in 1...numElements {
        let fwkTarget = TestLogHeader("Framework-\(i)")
        log.addEntry(fwkTarget)
        for j in 1...numElements {
            fwkTarget.addEntry(TestLogSection("Copy Foo_\(j).h"))

            let compile = TestLogSection("Compile Foo_\(j).m")
            for k in 1...numElements {
                compile.addMessage(TestLogMessage(type: .warning, message: "Warning number \(k)"))
            }
            fwkTarget.addEntry(compile)
        }
        fwkTarget.addEntry(TestLogSection("Link Foo_\(i)"))
        fwkTarget.addEntry(TestLogSection("Touch Foo_\(i).framework"))
    }

    // Add an app target.
    let appTarget = TestLogHeader("App")
    log.addEntry(appTarget)
    let compile = TestLogSection("Compile Class.m")
    compile.addMessage(TestLogMessage(type: .error, message: "Something went wrong"))
    compile.addMessage(TestLogMessage(type: .error, message: "Something else went wrong"))
    appTarget.addEntry(compile)
    let link = TestLogSection("Link App")
    link.addMessage(TestLogMessage(type: .warning, message: "Couldn't find the right framework"))
    appTarget.addEntry(link)
    appTarget.addEntry(TestLogSection("Copy Framework into App"))
    appTarget.addEntry(TestLogSection("Touch App.app"))

    return log
}

private func serializeCustomElementHierarchy(_ log: TestLogHeader) -> MsgPackSerializer {
    let sz = MsgPackSerializer()
    sz.serialize(log)
    return sz
}

// MARK: Classes to serialize a log structure

private class TestLogEntry: PolymorphicSerializable {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(title)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.title = try deserializer.deserialize()
    }

    static let implementations: [SerializableTypeCode: any PolymorphicSerializable.Type] = [
        0: TestLogEntry.self,
        1: TestLogHeader.self,
        2: TestLogSection.self,
    ]
}

private final class TestLogHeader: TestLogEntry {
    var subsections: [TestLogEntry]

    override init(_ title: String) {
        subsections = [TestLogEntry]()
        super.init(title)
    }

    func addEntry(_ entry: TestLogEntry) {
        subsections.append(entry)
    }

    override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(subsections)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.subsections = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

private final class TestLogSection: TestLogEntry {
    var messages: [TestLogMessage]

    override init(_ title: String) {
        messages = [TestLogMessage]()
        super.init(title)
    }

    func addMessage(_ message: TestLogMessage) {
        messages.append(message)
    }

    override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(messages)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.messages = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

private enum TestLogMessageType: String {
    case error
    case warning
    case note
}

private final class TestLogMessage: Serializable {
    let type: TestLogMessageType
    let message: String

    init(type: TestLogMessageType, message: String) {
        self.type = type
        self.message = message
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(type.rawValue)
        serializer.serialize(message)
        serializer.endAggregate()
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        guard let type = TestLogMessageType(rawValue: try deserializer.deserialize()) else { throw DeserializerError.deserializationFailed("Invalid TestLogMessageType.") }
        self.type = type
        self.message = try deserializer.deserialize()
    }
}
