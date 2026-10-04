import XCTest
@testable import GrokDeskCore

final class StudioWorkflowTests: XCTestCase {
    func testVideoBindingsAreDistinctAndUseActualBuildTool() {
        var board = StudioBoard(medium: "video")
        board.prompt = "A slow reveal"; board.startPath = "/tmp/start.png"; board.endPath = "/tmp/end.png"
        board.references = ["/tmp/person.png"]; board.voices = ["eve"]
        let request = imagineCommand(board: board, outputFolder: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertTrue(request.contains("reference_to_video"))
        XCTAssertTrue(request.contains("first_frame")); XCTAssertTrue(request.contains("last_frame"))
        XCTAssertTrue(request.contains("<IMAGE_1>")); XCTAssertTrue(request.contains("<AUDIO_0>"))
        XCTAssertFalse(request.contains("/imagine-video"))
    }
    func testOldBoardsRemainReadableAndPresetChangesBrief() throws {
        let original = StudioBoard()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        raw.removeValue(forKey: "voices"); raw.removeValue(forKey: "duration"); raw.removeValue(forKey: "resolution")
        var decoded = try JSONDecoder().decode(StudioBoard.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded.voices, [])
        CameraPreset.all[1].apply(to: &decoded)
        XCTAssertTrue(decoded.brief.contains(decoded.look!.camera))
        XCTAssertTrue(decoded.brief.contains("deep focus"))
        XCTAssertFalse(decoded.brief.contains("Natural perspective"))
        XCTAssertNotEqual(decoded.look, StudioLook())
    }
    func testStillAndEditCommandsUseInstalledToolParameters() {
        var still = StudioBoard(); still.aspect = "21:9"; still.prompt = "A quiet harbor"
        let image = imagineCommand(board: still, outputFolder: URL(fileURLWithPath: "/tmp/media"))
        XCTAssertTrue(image.hasPrefix("/imagine "))
        XCTAssertTrue(image.contains("Call image_gen once."))
        XCTAssertTrue(image.contains("aspect_ratio: 16:9"))
        var edit = StudioBoard(); edit.references = ["/tmp/one.png"]; edit.aspect = "9:16"
        XCTAssertTrue(imagineCommand(board: edit, outputFolder: URL(fileURLWithPath: "/tmp/media")).contains("omit aspect_ratio"))
        edit.references.append("/tmp/two.png")
        XCTAssertTrue(imagineCommand(board: edit, outputFolder: URL(fileURLWithPath: "/tmp/media")).contains("aspect_ratio: 9:16"))
        var clip = StudioBoard(medium: "video"); clip.duration = 99; clip.resolution = "1080p"; clip.voices = ["eve", "narrator"]
        let video = imagineCommand(board: clip, outputFolder: URL(fileURLWithPath: "/tmp/media"))
        XCTAssertTrue(video.contains("duration: 15")); XCTAssertTrue(video.contains("resolution_name: 720p"))
        var fullHD = StudioBoard(medium: "video"); fullHD.resolution = "1080p"; fullHD.prompt = "A quiet harbor"
        let hd = imagineCommand(board: fullHD, outputFolder: URL(fileURLWithPath: "/tmp/media"))
        XCTAssertTrue(hd.contains("resolution_name: 1080p")); XCTAssertTrue(hd.contains("Call image_to_video")); XCTAssertFalse(hd.contains("Call reference_to_video"))
        var referenced = StudioBoard(medium: "video"); referenced.resolution = "1080p"; referenced.references = ["/tmp/a.png"]
        capReferenceResolution(&referenced)
        XCTAssertEqual(referenced.resolution, "720p")
        XCTAssertTrue(video.contains("<AUDIO_0>: eve")); XCTAssertFalse(video.contains("narrator"))
        XCTAssertFalse(video.contains("/imagine-video"))
    }
    func testLibraryFolderOverrideAndReset() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(StudioLibraryLocation.current(defaults: defaults, home: home).path, StudioLibraryLocation.defaultRoot(home: home).path)
        let custom = URL(fileURLWithPath: "/Volumes/Media/Grok", isDirectory: true)
        StudioLibraryLocation.choose(custom, defaults: defaults)
        XCTAssertEqual(StudioLibraryLocation.current(defaults: defaults, home: home).path, custom.path)
        StudioLibraryLocation.reset(defaults: defaults)
        XCTAssertEqual(StudioLibraryLocation.current(defaults: defaults, home: home).path, StudioLibraryLocation.defaultRoot(home: home).path)
    }
    func testFinishedFilesAreCopiedAndInputsStayOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("shot.png")
        let input = root.appendingPathComponent("input.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: source); try Data([1]).write(to: input)
        let session = root.appendingPathComponent("session")
        let images = session.appendingPathComponent("images"); try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let relative = images.appendingPathComponent("1.jpg"); try Data([4, 4]).write(to: relative)
        let library = StudioLibrary(root: root.appendingPathComponent("library"))
        let text = "Saved \(source.path) and images/1.jpg. Input was \(input.path)."
        let urls = studioMediaURLs(in: text, session: session) + studioMedia(createdUnder: session, since: .distantPast)
        let adopted = library.adopt(urls, excluding: [input.standardizedFileURL.path])
        XCTAssertEqual(adopted.count, 2)
        XCTAssertEqual(try library.assets().count, 2)
        XCTAssertTrue(library.adopt([source], excluding: []).count == 1)
    }
    func testNestedSkillSourceAndNonInvocableFiltering() {
        let raw = #"{"skills":[{"name":"deploy","source":{"type":"plugin","plugin_name":"vercel","path":"/tmp/vercel/SKILL.md"},"userInvocable":true},{"name":"hidden","source":{"path":"/tmp/hidden"},"userInvocable":false}]}"#
        let skills = parseInspectCatalog(Data(raw.utf8)).skills
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].source, "/tmp/vercel/SKILL.md")
        XCTAssertEqual(skills[0].pluginName, "vercel")
    }
}
