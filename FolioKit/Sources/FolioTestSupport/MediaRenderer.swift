import AppKit
import AVFoundation
import CoreText
import CoreVideo
import Foundation

/// Makes realistic recordings and lesson videos for the test set: the text is
/// spoken with a system voice, and videos show it as slides while it's spoken.
public enum MediaRenderer {
    public enum Failure: Error {
        case noSpeech
        case writeFailed(String)
    }

    /// Speaks `text` into an audio file; .m4a files are AAC, anything else is
    /// uncompressed. Returns the recording's length in seconds.
    @discardableResult
    public static func writeRecording(_ text: String, to url: URL, language: String = "en-AU") async throws -> TimeInterval {
        let buffers = await speak(text, language: language)
        guard let format = buffers.first?.format else { throw Failure.noSpeech }
        var settings = format.settings
        if url.pathExtension.lowercased() == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
            ]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        var frames: AVAudioFramePosition = 0
        for buffer in buffers {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        return Double(frames) / format.sampleRate
    }

    /// A lesson video: a title slide, then the body a couple of sentences per
    /// slide, with the body spoken over the slides.
    public static func writeVideo(title: String?, body: String, to url: URL, language: String = "en-AU") async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "folio-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let narration = scratch.appending(path: "narration.m4a")
        let length = try await writeRecording(body, to: narration, language: language)
        let slides = [title].compactMap { $0 } + slideTexts(from: body)
        let silent = scratch.appending(path: "slides.mov")
        try await writeSlides(slides, length: length, to: silent)

        // Put the narration under the slides.
        let composition = AVMutableComposition()
        let video = AVURLAsset(url: silent)
        let audio = AVURLAsset(url: narration)
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        if let track = try await video.loadTracks(withMediaType: .video).first,
           let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(range, of: track, at: .zero)
        }
        if let track = try await audio.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = CMTimeRange(start: .zero, duration: try await audio.load(.duration))
            try target.insertTimeRange(audioRange, of: track, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.writeFailed("Couldn't export \(url.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: url)
        try await export.export(to: url, as: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    }

    // MARK: Speech

    private final class Collector: @unchecked Sendable {
        var buffers: [AVAudioPCMBuffer] = []
        var isDone = false
    }

    private static func speak(_ text: String, language: String) async -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        let collector = Collector()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, !collector.isDone else { return }
            if pcm.frameLength == 0 {
                collector.isDone = true
                continuation.finish()
            } else {
                collector.buffers.append(pcm)
            }
        }
        for await _ in stream {}
        return collector.buffers
    }

    // MARK: Slides

    /// Two sentences per slide.
    static func slideTexts(from body: String) -> [String] {
        var sentences: [String] = []
        body.enumerateSubstrings(in: body.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return stride(from: 0, to: sentences.count, by: 2).map { sentences[$0..<min($0 + 2, sentences.count)].joined(separator: " ") }
    }

    private static func writeSlides(_ slides: [String], length: TimeInterval, to url: URL) async throws {
        let size = CGSize(width: 1280, height: 720)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let perSlide = max(length / Double(max(slides.count, 1)), 2)
        for (index, slide) in slides.enumerated() {
            let buffer = try pixelBuffer(showing: slide, isTitle: index == 0, size: size)
            try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: CMTime(seconds: perSlide * Double(index), preferredTimescale: 600))
        }
        // Hold the last slide until the narration ends.
        let last = try pixelBuffer(showing: slides.last ?? "", isTitle: slides.count == 1, size: size)
        try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: last), with: CMTime(seconds: max(length, perSlide * Double(slides.count)), preferredTimescale: 600))
        receiver.finish()
        await writer.finishWriting()
        if writer.status == .failed {
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "Couldn't write \(url.lastPathComponent)")
        }
    }

    private static func pixelBuffer(showing text: String, isTitle: Bool, size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw Failure.writeFailed("Couldn't make a frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw Failure.writeFailed("Couldn't draw a frame") }

        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = NSFont.systemFont(ofSize: isTitle ? 58 : 40, weight: isTitle ? .bold : .regular)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 90, y: 90, width: size.width - 180, height: size.height - 180), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        return buffer
    }
}
