// Standalone deterministic assertion tests. These synthetic markers never make AX IPC calls.
import ApplicationServices
import Foundation

private struct AssertionFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SelectionFixture {
    var attributes: [String: CFTypeRef] = [:]
    var parameterizedValues: [String: CFTypeRef] = [:]
    var attributeCalls: [String] = []
    var parameterCalls: [(String, CFTypeRef)] = []

    func read() -> String? {
        AccessibilitySelectedText.read(attribute: { name in
            self.attributeCalls.append(name)
            return self.attributes[name]
        }, parameterized: { name, parameter in
            self.parameterCalls.append((name, parameter))
            return self.parameterizedValues[name]
        })
    }
}

@main
private struct SelectionTestRunner {
    private static var assertions = 0
    private static var failures = 0

    private static func check(_ value: @autoclosure () -> Bool, _ message: String,
                              file: StaticString = #fileID, line: UInt = #line) throws {
        assertions += 1
        if !value() { throw AssertionFailure(description: "\(file):\(line): \(message)") }
    }

    private static func range(_ location: Int = 3, _ length: Int = 5) -> AXValue {
        var value = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &value)!
    }

    private static func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            print("PASS \(name)")
        } catch {
            failures += 1
            print("FAIL \(name): \(error)")
        }
    }

    static func main() {
        print("Accessibility selected-text extraction fixtures (no live AX access)")
        test("direct selected text takes precedence over both range transports") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedText"] = "MiXeD" as CFString
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.attributes["AXSelectedTextRange"] = range()
            try check(fixture.read() == "MiXeD", "Do not normalize or replace direct selection")
            try check(fixture.attributeCalls == ["AXSelectedText"], "Do not inspect fallbacks after valid direct text")
            try check(fixture.parameterCalls.isEmpty, "No parameterized IPC for direct text")
        }
        test("markers-only web document returns selected text using opaque token") {
            let fixture = SelectionFixture()
            let marker = "synthetic-opaque-Chrome-marker" as CFString
            fixture.attributes["AXSelectedTextMarkerRange"] = marker
            fixture.parameterizedValues["AXLengthForTextMarkerRange"] = NSNumber(value: 5)
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "hello" as CFString
            try check(fixture.read() == "hello", "Marker selection must work without CFRange")
            try check(fixture.parameterCalls.map { $0.0 } == ["AXLengthForTextMarkerRange", "AXStringForTextMarkerRange"], "Read marker length then text")
            try check(fixture.parameterCalls.allSatisfy { CFEqual($0.1, marker) }, "Pass the opaque token back unchanged")
            try check(!fixture.attributeCalls.contains("AXSelectedTextRange"), "Do not fall through after marker success")
        }
        test("marker text works when optional length attribute is unsupported") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "can't" as CFString
            try check(fixture.read() == "can't", "An unavailable optional length must not reject text")
            try check(fixture.parameterCalls.count == 2, "Still request marker text")
        }
        test("empty direct text falls through to marker text") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedText"] = "" as CFString
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "selection" as CFString
            try check(fixture.read() == "selection", "Empty direct selection should not mask web selection")
        }
        test("marker selection takes precedence over ordinary CFRange") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.attributes["AXSelectedTextRange"] = range()
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "web" as CFString
            fixture.parameterizedValues["AXStringForRange"] = "native" as CFString
            try check(fixture.read() == "web", "Prefer valid document text-marker selection")
            try check(!fixture.attributeCalls.contains("AXSelectedTextRange"), "Avoid unnecessary native fallback")
        }
        test("ordinary nonempty CFRange remains supported") {
            let fixture = SelectionFixture()
            let nativeRange = range(42, 4)
            fixture.attributes["AXSelectedTextRange"] = nativeRange
            fixture.parameterizedValues["AXStringForRange"] = "word" as CFString
            try check(fixture.read() == "word", "Native CFRange should still return selection")
            try check(fixture.parameterCalls.count == 1, "Only native parameterized transport is used")
            try check(fixture.parameterCalls.first?.0 == "AXStringForRange", "Request native string parameter")
            try check(CFEqual(fixture.parameterCalls[0].1, nativeRange), "Preserve the CFRange parameter")
        }
        test("unusable marker falls back to ordinary range") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedTextMarkerRange"] = NSNumber(value: 123)
            fixture.attributes["AXSelectedTextRange"] = range()
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "" as CFString
            fixture.parameterizedValues["AXStringForRange"] = "native" as CFString
            try check(fixture.read() == "native", "Unsupported or malformed marker must not block native fallback")
            try check(fixture.parameterCalls.last?.0 == "AXStringForRange", "Native fallback must be reached")
        }
        test("all missing or empty selection transports return nil") {
            let missing = SelectionFixture()
            try check(missing.read() == nil, "Missing AX attributes should be harmless")
            let empty = SelectionFixture()
            empty.attributes["AXSelectedText"] = "" as CFString
            empty.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            empty.parameterizedValues["AXStringForTextMarkerRange"] = "" as CFString
            try check(empty.read() == nil, "Empty results are not a selection")
        }
        test("long marker length is rejected before fetching text") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.parameterizedValues["AXLengthForTextMarkerRange"] = NSNumber(value: 129)
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = "must-not-be-read" as CFString
            try check(fixture.read() == " ", "Overlong range uses rejection sentinel")
            try check(fixture.parameterCalls.map { $0.0 } == ["AXLengthForTextMarkerRange"], "Do not retrieve a long web selection")
        }
        test("oversized direct and marker UTF8 strings use rejection sentinel") {
            let direct = SelectionFixture()
            direct.attributes["AXSelectedText"] = String(repeating: "a", count: 257) as CFString
            try check(direct.read() == " ", "Reject direct string above 256 UTF8 bytes")
            try check(direct.parameterCalls.isEmpty, "Long direct selection must not probe alternate text")
            let marker = SelectionFixture()
            marker.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            marker.parameterizedValues["AXStringForTextMarkerRange"] = String(repeating: "中", count: 86) as CFString
            try check(marker.read() == " ", "Count UTF8 bytes rather than characters")
        }
        test("range boundaries permit 128 units but reject 129 before reading") {
            let allowed = SelectionFixture()
            allowed.attributes["AXSelectedTextRange"] = range(0, 128)
            allowed.parameterizedValues["AXStringForRange"] = String(repeating: "a", count: 128) as CFString
            try check(allowed.read()?.count == 128, "128 selected units is accepted for later word filtering")
            let oversized = SelectionFixture()
            oversized.attributes["AXSelectedTextRange"] = range(0, 129)
            try check(oversized.read() == " ", "129 selected units must be rejected")
            try check(oversized.parameterCalls.isEmpty, "Do not fetch long native selection")
        }
        test("malformed AXSelectedTextRange values never reach a CFRange cast") {
            for invalid in ["not-an-AXValue" as CFTypeRef, NSNumber(value: 7) as CFTypeRef] {
                let fixture = SelectionFixture()
                fixture.attributes["AXSelectedTextRange"] = invalid
                try check(fixture.read() == nil, "Reject non-AXValue without crashing")
                try check(fixture.parameterCalls.isEmpty, "Do not send malformed native range")
            }
            var point = CGPoint(x: 10, y: 20)
            let pointValue = AXValueCreate(.cgPoint, &point)!
            let wrongAXType = SelectionFixture()
            wrongAXType.attributes["AXSelectedTextRange"] = pointValue
            try check(wrongAXType.read() == nil, "An AXValue of another type is not a CFRange")
            try check(wrongAXType.parameterCalls.isEmpty, "Do not pass a CGPoint as a string range")
        }
        test("empty negative missing and overflowing ranges return nil") {
            for value in [range(0, 0), range(-1, 3), range(0, -1), range(Int.max, 1)] {
                let fixture = SelectionFixture()
                fixture.attributes["AXSelectedTextRange"] = value
                try check(fixture.read() == nil, "Invalid CFRange must not produce a selection")
                try check(fixture.parameterCalls.isEmpty, "Do not fetch invalid range")
            }
        }
        test("non-string parameterized results and malformed marker lengths are safe") {
            let fixture = SelectionFixture()
            fixture.attributes["AXSelectedText"] = NSNumber(value: 4)
            fixture.attributes["AXSelectedTextMarkerRange"] = "marker" as CFString
            fixture.parameterizedValues["AXLengthForTextMarkerRange"] = "not-a-number" as CFString
            fixture.parameterizedValues["AXStringForTextMarkerRange"] = NSNumber(value: 8)
            fixture.attributes["AXSelectedTextRange"] = range()
            fixture.parameterizedValues["AXStringForRange"] = NSNumber(value: 9)
            try check(fixture.read() == nil, "Malformed values must not be forced into a text representation")
            try check(fixture.parameterCalls.count == 3, "Attempt valid transports without crashing on unrelated types")
        }
        test("exact UTF8 byte limit and raw non-word text are preserved") {
            let boundary = SelectionFixture()
            boundary.attributes["AXSelectedText"] = String(repeating: "a", count: 256) as CFString
            try check(boundary.read()?.utf8.count == 256, "Exactly 256 bytes remains accepted")
            let raw = SelectionFixture()
            raw.attributes["AXSelectedText"] = "two words\n" as CFString
            try check(raw.read() == "two words\n", "English-word filtering belongs to monitor, not this transport")
        }
        print("15 fixture tests, \(assertions) assertions, \(failures) failed tests.")
        if failures != 0 { exit(1) }
    }
}
