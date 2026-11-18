import Foundation
import Models
import XCTest

final class MemoLinkTests: XCTestCase {
    func testRoundTripUsesTheServerAndMemoID() throws {
        let link = try XCTUnwrap(MemoLink(server: "HTTPS://MEMOS.EXAMPLE:443/workspace/", memoID: "memos/Note_ab-12"))
        XCTAssertEqual(link.server.absoluteString, "https://memos.example/workspace")
        XCTAssertEqual(link.memoID, "Note_ab-12")
        XCTAssertEqual(MemoLink(url: link.url), link)

        let account = Account.memosV1(host: "https://memos.example/workspace", id: "7", accessToken: "")
        XCTAssertEqual(link.remoteID(for: account), "memos/Note_ab-12")
    }

    func testMemoIDsAreScopedToTheConfiguredServer() throws {
        let link = try XCTUnwrap(MemoLink(server: "https://memos.example/workspace", memoID: "41"))
        let legacy = Account.memosV0(host: "https://memos.example/workspace/", id: "7", accessToken: "")
        XCTAssertEqual(link.remoteID(for: legacy), "41")
        XCTAssertFalse(link.matches(.local))
        for otherServer in ["http://memos.example/workspace", "https://memos.example:8443/workspace",
                            "https://memos.example/another", "https://other.example/workspace"] {
            let wrong = Account.memosV1(host: otherServer, id: "7", accessToken: "")
            XCTAssertNil(link.remoteID(for: wrong), otherServer)
        }
    }

    func testRejectsAmbiguousParametersAndMalformedIDs() throws {
        for address in ["moememos://memo?server=https://memos.example&id=note&id=other",
                        "moememos://memo?server=https://memos.example&server=https://other.example&id=note",
                        "moememos://memo?server=https://user:pass@memos.example&id=note",
                        "moememos://memo?server=https://memos.example&id=memos/%2E%2E%2Fother",
                        "moememos://memo?server=https://memos.example",
                        "moememos://memo?entity_id=legacy"] {
            XCTAssertNil(MemoLink(url: try XCTUnwrap(URL(string: address))), address)
        }
    }
}
