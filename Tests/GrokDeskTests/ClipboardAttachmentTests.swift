import AppKit
import XCTest
@testable import GrokDeskCore

@MainActor
final class ClipboardAttachmentTests: XCTestCase {
    func testFilePasteKeepsURLAndPlainTextIsNotAnAttachment() throws {
        let board=NSPasteboard(name:.init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent("example.pdf");try Data([0,255,1]).write(to:file)
        board.writeObjects([file as NSURL])
        XCTAssertEqual(try clipboardAttachments(from:board,directory:dir),[file])
        board.clearContents();board.setString("hello\nworld",forType:.string)
        XCTAssertNil(try clipboardAttachments(from:board,directory:dir))
        let parts=try promptParts(text:"Inspect the file",attachments:[file],capabilities:AgentCapabilities())
        XCTAssertTrue((parts.last?["text"] as? String)?.contains(file.path)==true)
    }
    func testBitmapPasteCreatesPersistentPNGAndFolderPasteHasActionableError() throws {
        let board=NSPasteboard(name:.init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.setColor(.red,atX:0,y:0)
        board.setData(bitmap.representation(using:.png,properties:[:])!,forType:.png)
        let files=try XCTUnwrap(clipboardAttachments(from:board,directory:dir))
        XCTAssertEqual(files.count,1);XCTAssertNotNil(NSImage(contentsOf:files[0]))
        board.clearContents();board.writeObjects([dir as NSURL])
        XCTAssertThrowsError(try clipboardAttachments(from:board,directory:dir))
    }
}
