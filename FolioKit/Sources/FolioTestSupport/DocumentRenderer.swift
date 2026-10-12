import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes realistic test documents: PDFs with a text layer, scanned PDFs
/// without one, Word and RTF files, and photos of handwritten notes.
public enum DocumentRenderer {
    public enum RenderError: Error {
        case cannotCreate(URL)
    }

    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    // MARK: Text documents

    public static func writePlainText(title: String?, body: String, to url: URL) throws {
        let text = [title, body].compactMap { $0 }.joined(separator: "\n\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a Word (.docx), RTF or OpenDocument file.
    public static func writeDocument(title: String?, body: String, to url: URL, as type: NSAttributedString.DocumentType) throws {
        let string = typed(title: title, body: body)
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if let title { attributes[.title] = title }
        let data = try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: attributes)
        try data.write(to: url)
    }

    /// Writes a PDF. With `scanned`, each page is an image with no text layer, like a scan.
    public static func writePDF(title: String?, body: String, to url: URL, scanned: Bool = false, seed: UInt64 = 1) throws {
        var mediaBox = a4
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw RenderError.cannotCreate(url) }
        let string = typed(title: title, body: body)
        let textRect = a4.insetBy(dx: 56, dy: 64)
        var random = SeededRandom(seed: seed)

        for range in pageRanges(of: string, in: textRect) {
            context.beginPDFPage(nil)
            if scanned {
                let page = scannedPage(string: string, range: range, random: &random)
                context.draw(page, in: a4)
            } else {
                draw(string, range: range, in: textRect, context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: Handwritten notes

    /// Writes a phone-photo-like image of handwritten notes on lined paper (JPEG or PNG by extension).
    public static func writeHandwrittenPhoto(title: String?, body: String, to url: URL, seed: UInt64 = 1) throws {
        var random = SeededRandom(seed: seed)
        let size = CGSize(width: 1500, height: 2000)
        guard let context = bitmapContext(size: size) else { throw RenderError.cannotCreate(url) }

        // A desk-coloured background with the page slightly rotated on it.
        context.setFillColor(CGColor(red: 0.42, green: 0.36, blue: 0.30, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: random.next(in: -0.035...0.035))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)

        let paper = CGRect(origin: .zero, size: size).insetBy(dx: 70, dy: 70)
        context.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1))
        context.fill(paper)
        context.setStrokeColor(CGColor(red: 0.62, green: 0.75, blue: 0.9, alpha: 0.7))
        context.setLineWidth(2)
        var y = paper.maxY - 150
        while y > paper.minY + 40 {
            context.move(to: CGPoint(x: paper.minX, y: y))
            context.addLine(to: CGPoint(x: paper.maxX, y: y))
            y -= 62
        }
        context.strokePath()
        context.setStrokeColor(CGColor(red: 0.9, green: 0.45, blue: 0.45, alpha: 0.7))
        context.move(to: CGPoint(x: paper.minX + 130, y: paper.minY))
        context.addLine(to: CGPoint(x: paper.minX + 130, y: paper.maxY))
        context.strokePath()

        let fonts = ["Noteworthy-Light", "BradleyHandITCTT-Bold", "ChalkboardSE-Regular", "MarkerFelt-Thin"]
        let fontName = fonts[Int(random.next(in: 0..<Double(fonts.count)))]
        let ink = [CGColor(red: 0.1, green: 0.15, blue: 0.45, alpha: 1), CGColor(gray: 0.22, alpha: 1)][Int(random.next(in: 0..<2))]
        let string = handwritten(title: title, body: body, fontName: fontName, ink: ink)
        draw(string, range: CFRange(location: 0, length: string.length), in: CGRect(x: paper.minX + 150, y: paper.minY + 60, width: paper.width - 200, height: paper.height - 150), context: context)

        addNoise(to: context, size: size, amount: 2500, random: &random)
        guard let image = context.makeImage() else { throw RenderError.cannotCreate(url) }
        try writeImage(image, to: url)
    }

    // MARK: Drawing

    private static func typed(title: String?, body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        if let title {
            let font = NSFont(name: "HelveticaNeue-Bold", size: 17) ?? .boldSystemFont(ofSize: 17)
            result.append(NSAttributedString(string: title + "\n\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        let font = NSFont(name: "HelveticaNeue", size: 11.5) ?? .systemFont(ofSize: 11.5)
        result.append(NSAttributedString(string: body, attributes: [.font: font, .paragraphStyle: paragraph]))
        return result
    }

    private static func handwritten(title: String?, body: String, fontName: String, ink: CGColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 62
        paragraph.maximumLineHeight = 62
        let color = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        if let title {
            let font = NSFont(name: fontName, size: 44) ?? .systemFont(ofSize: 44)
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: font, .paragraphStyle: paragraph, color: ink]))
        }
        let font = NSFont(name: fontName, size: 36) ?? .systemFont(ofSize: 36)
        result.append(NSAttributedString(string: body, attributes: [.font: font, .paragraphStyle: paragraph, color: ink]))
        return result
    }

    /// Splits text into page-sized ranges.
    private static func pageRanges(of string: NSAttributedString, in rect: CGRect) -> [CFRange] {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        var ranges: [CFRange] = []
        var start = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            ranges.append(visible)
            start += visible.length
        } while start < string.length
        return ranges.isEmpty ? [CFRange(location: 0, length: 0)] : ranges
    }

    private static func draw(_ string: NSAttributedString, range: CFRange, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, range, CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    /// A page rendered to an image, slightly grey, rotated and speckled like a scan.
    private static func scannedPage(string: NSAttributedString, range: CFRange, random: inout SeededRandom) -> CGImage {
        let scale: CGFloat = 2.2
        let size = CGSize(width: a4.width * scale, height: a4.height * scale)
        let context = bitmapContext(size: size)!
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: a4.midX, y: a4.midY)
        context.rotate(by: random.next(in: -0.012...0.012))
        context.translateBy(x: -a4.midX, y: -a4.midY)
        draw(string, range: range, in: a4.insetBy(dx: 56, dy: 64), context: context)
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        addNoise(to: context, size: size, amount: 4000, random: &random)
        return context.makeImage()!
    }

    private static func bitmapContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    private static func addNoise(to context: CGContext, size: CGSize, amount: Int, random: inout SeededRandom) {
        for _ in 0..<amount {
            let gray = random.next(in: 0.3...0.8)
            context.setFillColor(CGColor(gray: gray, alpha: random.next(in: 0.15...0.4)))
            let point = CGPoint(x: random.next(in: 0..<size.width), y: random.next(in: 0..<size.height))
            context.fill(CGRect(origin: point, size: CGSize(width: 2, height: 2)))
        }
    }

    private static func writeImage(_ image: CGImage, to url: URL) throws {
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw RenderError.cannotCreate(url)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotCreate(url) }
    }

    /// A photo of a diagram with almost no words: a benzene ring, the kind of
    /// thing text recognition can't sort but the on-device AI can see.
    public static func writeMoleculeDiagram(to url: URL) throws {
        let size = CGSize(width: 1200, height: 900)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.25, alpha: 1))
        context.setLineWidth(7)
        context.setLineCap(.round)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 220
        let corners = (0..<6).map { index -> CGPoint in
            let angle = CGFloat(index) * .pi / 3 + .pi / 6
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
        for index in 0..<6 {
            let a = corners[index], b = corners[(index + 1) % 6]
            context.move(to: a)
            context.addLine(to: b)
            if index % 2 == 0 {
                // The double bonds, drawn inside the ring.
                let inset: CGFloat = 0.82
                context.move(to: CGPoint(x: centre.x + (a.x - centre.x) * inset, y: centre.y + (a.y - centre.y) * inset))
                context.addLine(to: CGPoint(x: centre.x + (b.x - centre.x) * inset, y: centre.y + (b.y - centre.y) * inset))
            }
            // A bond out to a hydrogen atom.
            context.move(to: a)
            context.addLine(to: CGPoint(x: centre.x + (a.x - centre.x) * 1.45, y: centre.y + (a.y - centre.y) * 1.45))
        }
        context.strokePath()
        let font = CTFontCreateWithName("Noteworthy-Light" as CFString, 64, nil)
        for corner in corners {
            let point = CGPoint(x: centre.x + (corner.x - centre.x) * 1.62 - 18, y: centre.y + (corner.y - centre.y) * 1.62 - 22)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "H", attributes: [.font: font, .foregroundColor: CGColor(red: 0.1, green: 0.1, blue: 0.25, alpha: 1)]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

}

/// A small repeatable random generator (SplitMix64), so test files come out the same every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(nextUInt64() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }

    mutating func next(in range: Range<Double>) -> Double {
        range.lowerBound + Double(nextUInt64() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
