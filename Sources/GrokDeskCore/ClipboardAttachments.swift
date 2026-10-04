import AppKit
import Foundation

/// Reads only explicit file/image clipboard types. Text and HTML retain normal paste behavior.
@MainActor
public func clipboardAttachments(from pasteboard: NSPasteboard, directory: URL) throws -> [URL]? {
    if pasteboard.types?.contains(.fileURL) == true,
       let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        for url in urls {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw NSError(domain:"Clipboard",code:1,userInfo:[NSLocalizedDescriptionKey:"Use Choose workspace to add folders. Paste regular files here."])
            }
        }
        return urls
    }
    guard pasteboard.types?.contains(.png) == true || pasteboard.types?.contains(.tiff) == true else { return nil }
    guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain:"Clipboard",code:2,userInfo:[NSLocalizedDescriptionKey:"This clipboard image could not be read."])
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("Pasted image-" + UUID().uuidString.prefix(8) + ".png")
    try png.write(to: target, options: .atomic)
    return [target]
}
