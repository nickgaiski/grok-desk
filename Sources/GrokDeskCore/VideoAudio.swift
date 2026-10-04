import Foundation
import AVFoundation

@MainActor public enum VideoAudio {
    /// Rewrites only the desktop's saved copy; the provider's original is preserved.
    public static func removeAudio(from url: URL) async throws {
        let asset=AVURLAsset(url:url)
        guard !(try await asset.loadTracks(withMediaType:.audio)).isEmpty else{return}
        let videoTracks=try await asset.loadTracks(withMediaType:.video)
        guard !videoTracks.isEmpty else {throw failure("No video track was found.")}
        let composition=AVMutableComposition()
        let duration=try await asset.load(.duration)
        for track in videoTracks {
            guard let output=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw failure("Could not prepare a silent video.")}
            try output.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:track,at:.zero)
            output.preferredTransform=try await track.load(.preferredTransform)
        }
        guard let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else {throw failure("This video cannot be saved without audio.")}
        let type:AVFileType = url.pathExtension.lowercased()=="mov" ? .mov : url.pathExtension.lowercased()=="m4v" ? .m4v : .mp4
        guard export.supportedFileTypes.contains(type) else {throw failure("This video format cannot be exported without audio.")}
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".silent-"+UUID().uuidString).appendingPathExtension(url.pathExtension)
        defer{try? FileManager.default.removeItem(at:temporary)}
        export.outputURL=temporary;export.outputFileType=type
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else {throw export.error ?? failure("Silent-video export did not finish.")}
        guard try await AVURLAsset(url:temporary).loadTracks(withMediaType:.audio).isEmpty else {throw failure("The exported video still contains audio.")}
        _ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)
    }
    private static func failure(_ message:String)->NSError {NSError(domain:"VideoAudio",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
