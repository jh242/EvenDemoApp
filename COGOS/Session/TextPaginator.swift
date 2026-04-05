import Foundation
import UIKit

/// Splits text into lines that fit the glasses display at a 21px system font
/// over a 488px-wide canvas. Ports `EvenAIDataMethod.measureStringList` in
/// `lib/services/evenai.dart`.
///
/// Uses `NSAttributedString.boundingRect` with word-breaking heuristics to
/// approximate Flutter's `TextPainter` output.
@MainActor
enum TextPaginator {
    static let maxWidth: CGFloat = 488
    static let fontSize: CGFloat = 21

    /// Wraps text into display-width lines. Paragraphs split on '\n';
    /// empty paragraphs are skipped; results are trimmed.
    static func measureStringList(_ text: String, maxWidth w: CGFloat = maxWidth) -> [String] {
        let font = UIFont.systemFont(ofSize: fontSize)
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for paragraph in paragraphs {
            out.append(contentsOf: wrap(paragraph: paragraph, font: font, maxWidth: w))
        }
        return out
    }

    private static func wrap(paragraph: String, font: UIFont, maxWidth: CGFloat) -> [String] {
        // Word-by-word greedy fit. Falls back to character-level if single word
        // exceeds maxWidth.
        let words = paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if width(of: candidate, font: font) <= maxWidth {
                current = candidate
            } else {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                if width(of: word, font: font) <= maxWidth {
                    current = word
                } else {
                    // Break long word into character chunks.
                    var chunk = ""
                    for ch in word {
                        let candidate = chunk + String(ch)
                        if width(of: candidate, font: font) <= maxWidth {
                            chunk = candidate
                        } else {
                            if !chunk.isEmpty { lines.append(chunk) }
                            chunk = String(ch)
                        }
                    }
                    current = chunk
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func width(of string: String, font: UIFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (string as NSString).size(withAttributes: attrs)
        return ceil(size.width)
    }
}
