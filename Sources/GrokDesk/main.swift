import Foundation
import SwiftUI

GrokDeskApp.main()

func resolveGrokBinary(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    path: String? = ProcessInfo.processInfo.environment["PATH"]
) -> String {
    let preferred = home.appendingPathComponent(".grok/bin/grok").path
    if FileManager.default.fileExists(atPath: preferred) {
        return preferred
    }
    for directory in (path ?? "").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("grok").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return preferred
}
