import Foundation
import XCTest
@testable import MenuLauncher

final class DiagnosticsTests: XCTestCase {
    func testRotationPreservesCompleteRecordsAndSessionMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("launcher.log")
        let logger = DiagnosticLogger(url: url, limit: 1024)
        for index in 0..<40 {
            logger.write("test.event", ["index": String(index), "time": "cannot override metadata"])
        }
        logger.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), ["launcher.log", "launcher.log.1"])
        var records: [[String: String]] = []
        for path in [url.appendingPathExtension("1"), url] {
            let data = try Data(contentsOf: path)
            XCTAssertLessThanOrEqual(data.count, 1024)
            XCTAssertEqual(data.last, 10)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            records += try data.split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: String])
            }
        }
        XCTAssertEqual(records.last?["index"], "39")
        XCTAssertEqual(Set(records.compactMap { $0["session"] }).count, 1)
        for record in records {
            XCTAssertNotEqual(record["time"], "cannot override metadata")
            XCTAssertEqual(record["pid"], String(ProcessInfo.processInfo.processIdentifier))
            XCTAssertNotNil(Double(record["uptime"] ?? ""))
        }
    }
}
