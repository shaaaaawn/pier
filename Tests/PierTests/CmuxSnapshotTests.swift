import XCTest

@testable import Pier

final class CmuxSnapshotTests: XCTestCase {
  /// Realistic shape: a workspace, a surface whose parent is a pane that has
  /// no row of its own, and a process chain node -> bash -> kimi -> surface.
  let tsvWithoutPaneRow = """
    12.9\t1028612200\t22\tworkspace\tworkspace:4\twindow:1\tPersonal Agent
    9.2\t559616400\t10\tsurface\tsurface:19\tpane:6\tKimi
    4.0\t320515680\t1\tprocess\t94683\tsurface:19\tkimi
    0.0\t1261856\t1\tprocess\t5583\t94683\tbash
    0.1\t39966192\t1\tprocess\t5584\t5583\tnode
    """

  let tsvWithPaneRow = """
    12.9\t1028612200\t22\tworkspace\tworkspace:4\twindow:1\tPersonal Agent
    3.3\t100\t1\tpane\tpane:6\tworkspace:4\t
    9.2\t559616400\t10\tsurface\tsurface:19\tpane:6\tKimi
    4.0\t320515680\t1\tprocess\t94683\tsurface:19\tkimi
    0.1\t39966192\t1\tprocess\t5584\t94683\tnode
    """

  func testNestedProcessSurfaceWorkspaceChain() {
    let snapshot = CmuxSnapshot.parse(tsvWithPaneRow)
    let hit = snapshot.attribution(chain: [5584])
    XCTAssertEqual(hit?.surface, "Kimi")
    XCTAssertEqual(hit?.workspace, "Personal Agent")
  }

  func testWorkspaceFallbackWhenPaneRowMissing() {
    // surface's parent pane:6 has no row; single known workspace is the fallback.
    let snapshot = CmuxSnapshot.parse(tsvWithoutPaneRow)
    let hit = snapshot.attribution(chain: [5584])
    XCTAssertEqual(hit?.surface, "Kimi")
    XCTAssertEqual(hit?.workspace, "Personal Agent")
  }

  func testAncestorPidInChainMatches() {
    // The listening pid itself is not a cmux process, but an ancestor is.
    let snapshot = CmuxSnapshot.parse(tsvWithoutPaneRow)
    let hit = snapshot.attribution(chain: [99999, 5584])
    XCTAssertEqual(hit?.surface, "Kimi")
  }

  func testUnrelatedPidHasNoAttribution() {
    let snapshot = CmuxSnapshot.parse(tsvWithoutPaneRow)
    XCTAssertNil(snapshot.attribution(chain: [12345]))
  }

  func testGarbageInputTolerated() {
    let snapshot = CmuxSnapshot.parse("not\ttsv\n\n\u{01}\u{02}")
    XCTAssertNil(snapshot.attribution(chain: [1]))
  }
}
