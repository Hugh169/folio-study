import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Reads recordings and videos: what's said in the first few minutes, using
/// Apple's on-device speech recognition, and the text on screen in a few
/// frames of a video, such as a lesson's slides.
enum MediaReader {
    enum Failure: Error {
        case noSpeechModel
    }

    /// The spoken words in the first `limit` seconds, or "" if there's no sound.
    static func transcript(of url: URL, limit: TimeInterval, progress: (@Sendable (String) -> Void)?) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return "" }

        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale else { throw Failure.noSpeechModel }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // A one-off download that macOS shares between apps.
            progress?(String(localized: "Downloading Apple's speech model…", bundle: .module))
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noSpeechModel
        }

        progress?(String(localized: "Listening to the recording…", bundle: .module))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let words: String = {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }()
        _ = try await analyzer.analyzeSequence(audio(of: url, as: format, limit: limit))
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await words
    }

    /// Decodes the first `limit` seconds of the sound into buffers the analyser reads.
    private static func audio(of url: URL, as format: AVAudioFormat, limit: TimeInterval) -> AsyncThrowingStream<AnalyzerInput, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AnalyzerInput.self)
        let settings = format.settings
        let task = Task.detached {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    continuation.finish()
                    return
                }
                guard let pcmFormat = AVAudioFormat(settings: settings) else { throw CocoaError(.fileReadCorruptFile) }
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
                let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: settings))
                try reader.start()
                while !Task.isCancelled, let sample = try await provider.next() {
                    sample.withUnsafeSampleBuffer { sampleBuffer in
                        if let buffer = pcmBuffer(from: sampleBuffer, format: pcmFormat) {
                            continuation.yield(AnalyzerInput(buffer: buffer))
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Text on screen in a few frames spread through a video, without repeats.
    static func onScreenText(of url: URL, frames: Int = 4) async -> String {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty
        else { return "" }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)

        var lines: [String] = []
        var seen = Set<String>()
        for step in 0..<frames {
            let time = CMTime(seconds: duration.seconds * (Double(step) + 0.5) / Double(frames), preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time),
                  let text = try? await TextRecognizer.text(in: image)
            else { continue }
            for line in text.split(separator: "\n").map(String.init) where seen.insert(line.lowercased()).inserted {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The length of a recording or video, in seconds.
    static func duration(of url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        return duration.seconds
    }
}
