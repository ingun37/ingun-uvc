import AVFoundation
import Foundation

struct VideoCompilation {
    static func export(videoURL: URL, clips: [Clip], destination: URL) async throws {
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompilationError.noVideo
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let selected = clips.filter(\.included)
        guard !selected.isEmpty else { throw CompilationError.noClips }

        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CompilationError.trackSetup }
        outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let outputAudio = audioTrack.map { _ in (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }} ?? []
        if audioTrack != nil && outputAudio.count != 2 { throw CompilationError.trackSetup }
        let audioParameters = outputAudio.map { AVMutableAudioMixInputParameters(track: $0) }
        var cursor = CMTime.zero
        for (index, clip) in selected.enumerated() {
            let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.end, preferredTimescale: 600))
            try outputVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack {
                // Audio extends across the video cut. Alternating tracks allow tails and heads to overlap.
                let head = index == 0 ? 0 : min(0.25, clip.start, selected[index - 1].end - selected[index - 1].start)
                let tail = index == selected.count - 1 ? 0 : min(0.25, duration - clip.end, selected[index + 1].end - selected[index + 1].start)
                let audioStart = max(0, clip.start - head)
                let audioEnd = min(duration, clip.end + tail)
                let audioAt = cursor - CMTime(seconds: clip.start - audioStart, preferredTimescale: 600)
                try outputAudio[index % 2].insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: audioStart, preferredTimescale: 600),
                                end: CMTime(seconds: audioEnd, preferredTimescale: 600)),
                    of: audioTrack, at: audioAt)
                let parameters = audioParameters[index % 2]
                if head > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: audioAt, duration: CMTime(seconds: head, preferredTimescale: 600)))
                } else {
                    parameters.setVolume(1, at: audioAt)
                }
                if tail > 0 {
                    let fadeAt = cursor + range.duration
                    parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: fadeAt, duration: CMTime(seconds: tail, preferredTimescale: 600)))
                }
            }
            cursor = cursor + range.duration
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CompilationError.exportSetup
        }
        if !audioParameters.isEmpty { session.audioMix = mix }
        try await session.export(to: staged, as: .mp4)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    enum CompilationError: LocalizedError {
        case noVideo, noClips, trackSetup, exportSetup
        var errorDescription: String? {
            switch self {
            case .noVideo: "The selected file has no video track."
            case .noClips: "Include at least one clip before exporting."
            case .trackSetup: "Could not create the compilation tracks."
            case .exportSetup: "Could not create a video export session."
            }
        }
    }
}
