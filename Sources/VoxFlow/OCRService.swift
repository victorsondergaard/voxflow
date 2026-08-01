import AppKit
import Foundation
import PDFKit
import Vision

enum OCRError: Error, LocalizedError {
    case unreadableFile
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Could not open that file as a PDF or image."
        case .noTextFound:
            return "No readable text was found in the document."
        }
    }
}

/// Fully on-device OCR built on Apple's Vision framework: fast even on Intel,
/// excellent accuracy, zero downloads, nothing leaves the Mac.
///
/// Engine seam: this type is the single place documents become text. A
/// heavyweight model backend (e.g. baidu/Unlimited-OCR, a 30B-parameter
/// document parser) can be added later as an alternative implementation for
/// Macs with the memory and GPU to run it — the rest of the app won't change.
enum OCRService {
    static let supportedExtensions = ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp", "gif", "bmp"]

    /// Extracts text from a PDF or image file. Runs synchronously — call it
    /// off the main thread. `progress` is invoked with human-readable status.
    static func extractText(from url: URL, progress: @escaping (String) -> Void) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            return try extractFromPDF(url: url, progress: progress)
        }
        guard
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw OCRError.unreadableFile
        }
        progress("Reading image…")
        let text = try recognize(cgImage: cgImage)
        guard !text.isEmpty else { throw OCRError.noTextFound }
        return text
    }

    private static func extractFromPDF(url: URL, progress: @escaping (String) -> Void) throws -> String {
        guard let document = PDFDocument(url: url) else { throw OCRError.unreadableFile }
        var pageTexts: [String] = []
        for index in 0..<document.pageCount {
            progress("Reading page \(index + 1) of \(document.pageCount)…")
            guard let page = document.page(at: index) else { continue }

            // If the PDF already has a real text layer, use it — no OCR needed.
            if let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               existing.count > 10 {
                pageTexts.append(existing)
                continue
            }

            // Scanned page: render at 2.5x and run Vision on the bitmap.
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.5
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }
            if let text = try? recognize(cgImage: cgImage), !text.isEmpty {
                pageTexts.append(text)
            }
        }
        let joined = pageTexts.joined(separator: "\n\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noTextFound
        }
        return joined
    }

    private static func recognize(cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "da-DK", "es-ES"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
