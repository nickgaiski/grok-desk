import XCTest
@testable import GrokDeskCore

final class StudioAgentTests: XCTestCase {
    func testModeDraftsAndSessionAssociationSurviveReload() throws {
        var state = StudioSessionState()
        state.mode = .agent
        state.agentPrompt = "Make three matching scenes"
        state.sessionID = "media-session"
        state.attachments = ["/tmp/reference.png", "/tmp/clip.mp4"]
        let restored = try JSONDecoder().decode(StudioSessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        state.mode = .video
        XCTAssertEqual(state.agentPrompt, restored.agentPrompt)
        XCTAssertEqual(state.sessionID, "media-session")
    }
    func testBusyStudioRejectsWorkspaceRetargetWithoutMutatingAssociationOrDraft() throws {
        var state=StudioSessionState();state.cwd="/tmp/project-A";state.sessionID="agent-A";state.agentPrompt="Keep this follow-up";state.attachments=["/tmp/reference.png"]
        let before=state
        XCTAssertThrowsError(try state.validateSubmission(workspace:"/tmp/project-B",whileRunning:true))
        XCTAssertEqual(state,before)
        XCTAssertNoThrow(try state.validateSubmission(workspace:"/tmp/project-A",whileRunning:true))
        XCTAssertNoThrow(try state.validateSubmission(workspace:"/tmp/project-B",whileRunning:false))
    }
    func testSavedCanvasKeepsItsWorkspaceAndRecognizesCurrentDraft() {
        var canvas=StudioSessionState();canvas.sessionID="saved-A";canvas.cwd="/tmp/A";canvas.agentPrompt="Unsaved follow-up"
        var menuSnapshot=canvas;menuSnapshot.agentPrompt="Old draft"
        XCTAssertTrue(canvas.isCurrentCanvas(menuSnapshot))
        XCTAssertEqual(canvas.submissionWorkspace(requested:"/tmp/B",whileRunning:false),"/tmp/A")
        XCTAssertEqual(canvas.submissionWorkspace(requested:"/tmp/B",whileRunning:true),"/tmp/A")
        let newCanvas=StudioSessionState()
        XCTAssertFalse(canvas.isCurrentCanvas(newCanvas))
        XCTAssertEqual(newCanvas.submissionWorkspace(requested:"/tmp/B",whileRunning:false),"/tmp/B")
    }
    func testVideoReferenceTransitionCapsResolutionWithoutRemoving1080Option() {
        var shot = StudioBoard(medium: "video")
        shot.resolution = "1080p"
        XCTAssertEqual(studioResolution(for: shot), "1080p")
        shot.references = ["/tmp/reference.png"]
        capReferenceResolution(&shot)
        XCTAssertEqual(shot.resolution, "720p")
        shot.references = []
        shot.resolution = "1080p"
        XCTAssertEqual(studioResolution(for: shot), "1080p")
    }
}
