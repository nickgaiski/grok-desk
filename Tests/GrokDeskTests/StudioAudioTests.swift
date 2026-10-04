import XCTest
import AVFoundation
@testable import GrokDeskCore
final class StudioAudioTests: XCTestCase {
    @MainActor func testSilentExportRemovesAudioAndPreservesVideo() async throws {
        let source=try XCTUnwrap(Bundle.module.url(forResource:"audio-video",withExtension:"mp4",subdirectory:"Fixtures"))
        let copy=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try FileManager.default.copyItem(at:source,to:copy);defer{try? FileManager.default.removeItem(at:copy)}
        let originalAudio=try await AVURLAsset(url:copy).loadTracks(withMediaType:.audio)
        XCTAssertFalse(originalAudio.isEmpty)
        try await VideoAudio.removeAudio(from:copy)
        let result=AVURLAsset(url:copy)
        let audio=try await result.loadTracks(withMediaType:.audio),video=try await result.loadTracks(withMediaType:.video)
        XCTAssertTrue(audio.isEmpty);XCTAssertFalse(video.isEmpty)
    }
    func testSilentBoardRoundTripSuppressesVoiceInputs() throws {
        var board=StudioBoard(medium:"video");board.audioEnabled=false;board.voices=["eve"];board.resolution="1080p"
        let restored=try JSONDecoder().decode(StudioBoard.self,from:JSONEncoder().encode(board))
        XCTAssertFalse(restored.audioEnabled)
        XCTAssertEqual(studioResolution(for:restored),"1080p")
        let request=imagineCommand(board:restored,outputFolder:URL(fileURLWithPath:"/tmp/test"))
        XCTAssertTrue(request.contains("generate_audio: false"))
        XCTAssertTrue(request.contains("resolution_name: 1080p"))
        XCTAssertFalse(request.contains("voices[0]"))
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(board)) as? [String:Any]);legacy.removeValue(forKey:"audioEnabled")
        XCTAssertTrue(try JSONDecoder().decode(StudioBoard.self,from:JSONSerialization.data(withJSONObject:legacy)).audioEnabled)
    }
}
