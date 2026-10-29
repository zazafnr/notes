import XCTest
@testable import FreeNotesLogic

final class StellaTests: XCTestCase {
    func testServerAddress() {
        XCTAssertEqual(StellaLogic.normalizedServer("stella.example.at/")?.absoluteString, "https://stella.example.at")
        XCTAssertEqual(StellaLogic.normalizedServer(" http://localhost:8787 ")?.absoluteString, "http://localhost:8787")
        XCTAssertNil(StellaLogic.normalizedServer(""))
        XCTAssertNil(StellaLogic.normalizedServer("kein server"))
    }

    func testSameSubject() {
        XCTAssertTrue(StellaLogic.sameSubject("Französisch", "franzosisch"))
        XCTAssertTrue(StellaLogic.sameSubject("Französisch", "Franz"))
        XCTAssertTrue(StellaLogic.sameSubject("Mathe", "Mathematik"))
        XCTAssertTrue(StellaLogic.sameSubject("Mathe-Heft", "Mathe"))
        XCTAssertTrue(StellaLogic.sameSubject("Franz Heft 6B", "Französisch"))
        XCTAssertFalse(StellaLogic.sameSubject("Mathe", "Deutsch"))
        XCTAssertFalse(StellaLogic.sameSubject("Mathematikum", "Mathe"))
    }

    func testFindsNotebookBySubjectThenTitle() {
        let franz = Subject(name: "Französisch", colorIndex: 1, symbol: "globe")
        let math = Subject(name: "Mathe", colorIndex: 0, symbol: "function")
        var old = Notebook(title: "Altes Heft", subjectID: franz.id, colorIndex: 1, paper: .lined, pages: [])
        old.modified = Date(timeIntervalSince1970: 100)
        var current = Notebook(title: "Schulübungen", subjectID: franz.id, colorIndex: 1, paper: .lined, pages: [])
        current.modified = Date(timeIntervalSince1970: 200)
        let latin = Notebook(title: "Latein-Heft", subjectID: nil, colorIndex: 2, paper: .lined, pages: [])
        let mathNB = Notebook(title: "Mathe-Heft", subjectID: math.id, colorIndex: 0, paper: .grid, pages: [])
        let all = [old, current, latin, mathNB]

        XCTAssertEqual(StellaLogic.notebookID(forSubject: "Französisch", subjects: [franz, math], notebooks: all), current.id)
        XCTAssertEqual(StellaLogic.notebookID(forSubject: "Latein", subjects: [franz, math], notebooks: all), latin.id)
        XCTAssertNil(StellaLogic.notebookID(forSubject: "Biologie", subjects: [franz, math], notebooks: all))
    }

    func testEntryDecodingAndHeader() throws {
        let json = #"[{"id":"a1","subject":"Französisch","title":"Französisch HÜ","page":"45","exercises":"16","due":"2026-10-30","text":"__S. 45 Nr. 16__\n\n1) Oui, elle y va.","created":"2026-10-29T12:00:00Z"}]"#
        let entries = try JSONDecoder().decode([StellaEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.subject, "Französisch")
        XCTAssertEqual(StellaLogic.notebookText(for: entries[0]), "__S. 45 Nr. 16__\n\n1) Oui, elle y va.")
        let plain = StellaEntry(id: "b", subject: nil, title: "Mathe HÜ", page: nil, exercises: nil, due: nil, text: "2x = 8")
        XCTAssertEqual(StellaLogic.notebookText(for: plain), "__Mathe HÜ__\n\n2x = 8")
    }

    func testErrorMessage() {
        XCTAssertEqual(StellaLogic.errorMessage(from: Data(#"{"error":"E-Mail oder Passwort falsch."}"#.utf8), status: 401), "E-Mail oder Passwort falsch.")
        XCTAssertEqual(StellaLogic.errorMessage(from: Data(), status: 502), "Stella antwortet nicht richtig (Fehler 502).")
    }
}
