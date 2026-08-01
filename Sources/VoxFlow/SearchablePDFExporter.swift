import AppKit
import Foundation
import PDFKit
import Vision

enum SearchablePDFError: Error, LocalizedError {
    case unreadableFile
    case cantCreateContext

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Could not open that file as a PDF or image."
        case .cantCreateContext:
            return "Could not create the output PDF."
        }
    }
}

/// Turns a scanned PDF or an image into a SEARCHABLE PDF: the original page
/// imagery stays pixel-identical, and an invisible text layer is drawn exactly
/// over each recognized word — so selecting, searching, copying and macOS's
/// built-in read-aloud all work. (The on-device equivalent of OCRmyPDF.)
///
/// Pages that already have a real text layer are copied through untouched.
enum SearchablePDFExporter {

    /// Runs synchronously — call off the main thread.
    static func export(from input: URL, to output: URL, progress: @escaping (String) -> Void) throws {
        if input.pathExtension.lowercased() == "pdf" {
            try exportPDF(input: input, output: output, progress: progress)
        } else {
            try exportImage(input: input, output: output, progress: progress)
        }
    }

    private static func exportImage(input: URL, output: URL, progress: @escaping (String) -> Void) throws {
        guard
            let image = NSImage(contentsOf: input),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw SearchablePDFError.unreadableFile
        }
        var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw SearchablePDFError.cantCreateContext
        }
        progress("Recognizing text…")
        let observations = try recognize(cgImage: cgImage)
        context.beginPDFPage(nil)
        context.draw(cgImage, in: mediaBox)
        drawInvisibleText(observations, in: context, pageRect: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    private static func exportPDF(input: URL, output: URL, progress: @escaping (String) -> Void) throws {
        guard let document = PDFDocument(url: input), document.pageCount > 0,
              let firstPage = document.page(at: 0) else {
            throw SearchablePDFError.unreadableFile
        }
        var firstBox = firstPage.bounds(for: .mediaBox)
        guard let context = CGContext(output as CFURL, mediaBox: &firstBox, nil) else {
            throw SearchablePDFError.cantCreateContext
        }
        for index in 0..<document.pageCount {
            progress("Page \(index + 1) of \(document.pageCount)…")
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            context.beginPDFPage(pageInfo)

            let existingText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingText.count > 10 {
                // Already searchable: pass the page through with its text intact.
                context.saveGState()
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
            } else {
                // Scanned page: draw the imagery, then the invisible text layer.
                let scale: CGFloat = 2.5
                let thumbnail = page.thumbnail(of: NSSize(width: box.width * scale,
                                                          height: box.height * scale),
                                               for: .mediaBox)
                if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.draw(cgImage, in: box)
                    if let observations = try? recognize(cgImage: cgImage) {
                        drawInvisibleText(observations, in: context, pageRect: box)
                    }
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func recognize(cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "da-DK", "es-ES"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Draws each recognized string in invisible render mode, scaled so its
    /// width and height match the word's bounding box — selection highlights
    /// land precisely on the printed words.
    private static func drawInvisibleText(_ observations: [VNRecognizedTextObservation],
                                          in context: CGContext, pageRect: CGRect) {
        let baseSize: CGFloat = 12
        let font = CTFontCreateWithName("Helvetica" as CFString, baseSize, nil)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { continue }
            // Vision bounding boxes are normalized, origin bottom-left — like PDF.
            let box = observation.boundingBox
            let rect = CGRect(x: pageRect.origin.x + box.origin.x * pageRect.width,
                              y: pageRect.origin.y + box.origin.y * pageRect.height,
                              width: box.width * pageRect.width,
                              height: box.height * pageRect.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            let attributed = NSAttributedString(
                string: candidate.string,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let measuredWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard measuredWidth > 0 else { continue }

            context.saveGState()
            context.setTextDrawingMode(.invisible)
            context.textMatrix = CGAffineTransform(scaleX: rect.width / measuredWidth,
                                                   y: rect.height / baseSize)
            context.textPosition = CGPoint(x: rect.origin.x,
                                           y: rect.origin.y + rect.height * 0.22)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
