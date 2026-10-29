import XCTest
@testable import WordSlide

final class EnglishWordTests: XCTestCase {
    func testSelectedWordNormalization() {
        XCTAssertEqual(EnglishWord.normalize("  “Serendipity,”\n"), "serendipity")
        XCTAssertEqual(EnglishWord.normalize("can’t"), "can't")
        XCTAssertEqual(EnglishWord.normalize("well-being"), "well-being")
        XCTAssertEqual(EnglishWord.normalize("O'Reilly"), "o'reilly")
    }
    func testRejectsSentencesNumbersAndUnexpectedScripts() {
        for value in ["", "hello world", "hello\nworld", "abc123", "你好", "test/path", "a--b", "-word", "'word'", String(repeating: "a", count: 65)] {
            XCTAssertNil(EnglishWord.normalize(value), value)
        }
    }
}
