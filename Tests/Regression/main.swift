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
    try testVideoRoundTrip()
    try testRemotePoint()
    print("PASS video packets decode (H.264, HEVC) and input follows the letterbox")
    try testViewerPairing()
    print("PASS iPhone pairs as a viewer")
    try testReach()
    print("PASS a Mac is reached by name, Tailscale name, then its paired address")
    try testFrameWindow()
    print("PASS frame window opens up over a long link and backs off when it fills")
    try testDisplayFit()
    print("PASS a dark display takes the mode the viewer's screen shows best")
    try testClip()
    print("PASS a clipboard crosses the wire; screenshots go as PNG; Finder files are refused")
    try testFiles()
    print("PASS Finder files cross on their own connection: folders, big files, safe names, nothing left half-done")
    try testSeal()
    try testFragments()
    try testIndependentFrames()
    try testInputOrder()
    try testLossyLink()
    try testVideoLink()
    print("PASS video datagrams: sealed, repaired after loss, independent with LTR; input over UDP applied once, in order")
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
