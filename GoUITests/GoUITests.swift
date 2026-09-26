//
//  GoUITests.swift
//  GoUITests
//
//  Launch smoke test: Go starts as a menu bar app without crashing.
//

import XCTest

final class GoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
    }
}
