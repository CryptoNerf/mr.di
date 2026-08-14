import CoreGraphics
import Vision

enum OCRError: LocalizedError {
    case nothingFound
    var errorDescription: String? { "Текст в этой области не распознан" }
}

enum OCR {
    /// Распознаём только английский: словарь всё равно англо-русский,
    /// а сужение языка заметно повышает точность на коротких фрагментах.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw OCRError.nothingFound }

        let text = lines.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(400))
    }
}
