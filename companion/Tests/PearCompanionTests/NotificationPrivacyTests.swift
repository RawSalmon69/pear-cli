import XCTest
@testable import PearCompanion

/// A notification body is drawn as an on-screen banner and kept in Notification
/// Center until dismissed, so it must never carry grabbed content. Round 11 of
/// the app audit fixed the same class of leak on the pasteboard exit
/// (`org.nspasteboard.ConcealedType`); this is the OCR / QR exit.
final class NotificationPrivacyTests: XCTestCase {
    func testSummaryNeverEchoesTheContent() {
        let secret = "hunter2 correct horse battery staple"
        let summary = OCRService.summary(of: secret)
        XCTAssertFalse(summary.contains("hunter2"), "the summary must not quote the text")
        XCTAssertFalse(summary.contains("horse"))
        XCTAssertEqual(summary, "5 words · 36 characters")
    }

    func testSummaryCountsSingleWord() {
        XCTAssertEqual(OCRService.summary(of: "hunter2"), "7 characters")
    }

    func testSummarySingularCharacter() {
        XCTAssertEqual(OCRService.summary(of: "x"), "1 character")
    }

    func testWifiPayloadIsNotOpenableSoItNeverReachesTheBanner() {
        // The QR notification shows the payload only for an http(s) link, which
        // is exactly what `openableURL` gates. A Wi-Fi credential or a TOTP
        // enrolment secret must not qualify.
        XCTAssertNil(QRCode.openableURL(in: ["WIFI:T:WPA;S:HomeNet;P:hunter2;;"]))
        XCTAssertNil(QRCode.openableURL(in: ["otpauth://totp/Pear?secret=JBSWY3DPEHPK3PXP"]))
        XCTAssertNil(QRCode.openableURL(in: ["file:///Users/someone/secrets.txt"]))
    }

    func testHttpLinkStillOpenable() throws {
        let url = try XCTUnwrap(QRCode.openableURL(in: ["https://example.com/x"]))
        XCTAssertEqual(url.absoluteString, "https://example.com/x")
    }

    func testSecretPayloadSummaryHidesIt() {
        let summary = OCRService.summary(of: "WIFI:T:WPA;S:HomeNet;P:hunter2;;")
        XCTAssertFalse(summary.contains("hunter2"))
        XCTAssertFalse(summary.contains("HomeNet"))
    }
}
