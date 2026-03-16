import XCTest
@testable import WorldTree

final class JSONEscapingTests: XCTestCase {
    func testEscapesQuotesSlashesAndNewlines() {
        let escaped = escapeJSONString("say \"hi\" \\\nnext")

        XCTAssertEqual(escaped, #"say \"hi\" \\\nnext"#)
    }

    func testEscapesASCIIControlCharacters() {
        let escaped = escapeJSONString("\u{01}\u{08}\u{0C}\t")

        XCTAssertEqual(escaped, #"\u0001\b\f\t"#)
    }

    func testPreservesUnicodeScalars() {
        let escaped = escapeJSONString("Cortana 💠")

        XCTAssertEqual(escaped, "Cortana 💠")
    }
}
