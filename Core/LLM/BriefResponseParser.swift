import Foundation
import CoreFoundation

// EVO-Coder envelope structure retained; Planner hardened numeric and Unicode boundaries.
enum BriefResponseError: Error, Equatable { case malformedEnvelope, outputLimit, missingFinal, provider(Int) }
struct ParsedBriefResponse: Sendable, Equatable {
    let content: Data
    let inputTokens: Int?
    let outputTokens: Int?
    let finishReason: String?
}

enum BriefResponseParser {
    static func parse(_ data: Data) throws -> ParsedBriefResponse {
        guard data.count <= 100_000,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BriefResponseError.malformedEnvelope }
        if let raw = envelope["base_resp"] {
            guard let base = raw as? [String: Any] else { throw BriefResponseError.malformedEnvelope }
            if let code = base["status_code"] {
                guard let n = integer(code) else { throw BriefResponseError.malformedEnvelope }
                if n != 0 { throw BriefResponseError.provider(n) }
            }
        }
        guard let choices = envelope["choices"] as? [[String: Any]], let first = choices.first else { throw BriefResponseError.malformedEnvelope }
        let finish = first["finish_reason"] as? String
        if finish == "length" { throw BriefResponseError.outputLimit }
        guard let message = first["message"] as? [String: Any] else { throw BriefResponseError.missingFinal }
        var text: String
        if let value = message["content"] as? String { text = value }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { part -> String? in
                guard let type = part["type"] as? String, ["text","output_text"].contains(type) else { return nil }
                return part["text"] as? String
            }.joined()
        } else { throw BriefResponseError.missingFinal }
        // Ranges always belong to the original String: Unicode case folding may change length.
        for tag in ["think","thinking","reasoning"] {
            while let open = text.range(of: "<\(tag)>", options: .caseInsensitive) {
                guard let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) else { throw BriefResponseError.missingFinal }
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```") {
            let lines = text.components(separatedBy: "\n")
            if lines.count >= 3, ["```", "```json"].contains(lines[0]), lines.last == "```" {
                text = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { throw BriefResponseError.missingFinal }
        let final = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: final)) is [String: Any] else { throw BriefResponseError.malformedEnvelope }
        let usage = envelope["usage"] as? [String: Any]
        return ParsedBriefResponse(content: final, inputTokens: nonnegative(usage?["prompt_tokens"]),
            outputTokens: nonnegative(usage?["completion_tokens"]), finishReason: finish.flatMap { $0.count <= 40 ? $0 : nil })
    }
    private static func integer(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
    private static func nonnegative(_ raw: Any?) -> Int? {
        guard let raw, let value = integer(raw), value >= 0 else { return nil }; return value
    }
}
