import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(lc3_swiftTests.allTests),
    ]
}
#endif