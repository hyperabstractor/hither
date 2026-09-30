import Foundation

struct RegressionFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) throws {
    guard actual == expected else { throw RegressionFailure(message: "\(file):\(line): expected \(expected), got \(actual)") }
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws {
    guard value == nil else { throw RegressionFailure(message: "\(file):\(line): expected nil, got \(value!)") }
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    try expectEqual(value, true, file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    try expectEqual(value, false, file: file, line: line)
}

do {
    try testWindowPolicy()
    print("PASS window selection and overlay classification")
    try testWire()
    print("PASS terminal message delivery and connection closure")
    let arguments = CommandLine.arguments
    if arguments.count == 4, arguments[1] == "--remote" {
        try testMissingRemoteWindow(host: arguments[2], app: arguments[3], throughRelay: false)
        try testMissingRemoteWindow(host: arguments[2], app: arguments[3], throughRelay: true)
        print("PASS missing-window rejection and terminal delivery on paired host, direct and through relay")
    }
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
