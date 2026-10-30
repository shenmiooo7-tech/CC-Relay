import XCTest

// Ordinary arguments let async integration observations finish before XCTest's autoclosures run.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotEqual(actual, expected, file: file, line: line)
}
func expectTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(actual, file: file, line: line)
}
func expectFalse(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(actual, file: file, line: line)
}
func expectNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(actual, file: file, line: line)
}
func require<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(actual, file: file, line: line)
}
