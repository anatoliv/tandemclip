import Foundation

/// Local heuristics that catch likely secrets before they broadcast — the
/// backstop for apps that don't set the nspasteboard concealed marker.
/// Conservative on purpose: a false hold costs one click ("Send anyway"),
/// a false send costs a leaked credential.
enum SecretGuard {
    struct Finding: Equatable {
        let reason: String
    }

    /// Non-nil when the text looks like a secret.
    static func assess(_ text: String) -> Finding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 10_000 else { return nil }

        if let f = knownKeyShape(trimmed) { return f }
        if let f = privateKeyBlock(trimmed) { return f }
        if let f = jwt(trimmed) { return f }
        if let f = credentialAssignment(trimmed) { return f }
        if let f = paymentCard(trimmed) { return f }
        if let f = iban(trimmed) { return f }
        if let f = highEntropyToken(trimmed) { return f }
        return nil
    }

    /// Well-known credential prefixes (exact, cheap, near-zero false positives).
    private static func knownKeyShape(_ text: String) -> Finding? {
        let patterns: [(String, String)] = [
            (#"\bsk-[A-Za-z0-9_-]{20,}"#, "API key"),
            (#"\b(sk|rk)_live_[A-Za-z0-9]{20,}"#, "Stripe live key"),
            (#"\bghp_[A-Za-z0-9]{20,}"#, "GitHub token"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "GitHub token"),
            (#"\bglpat-[A-Za-z0-9_-]{20,}"#, "GitLab token"),
            (#"\bxox[bpars]-[A-Za-z0-9-]{10,}"#, "Slack token"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "AWS access key"),
            (#"\bAIza[A-Za-z0-9_-]{30,}"#, "Google API key"),
            (#"\bya29\.[A-Za-z0-9_-]{20,}"#, "Google OAuth token"),
            (#"\bnpm_[A-Za-z0-9]{30,}"#, "npm token"),
            (#"\bshpat_[a-f0-9]{32,}"#, "Shopify token"),
            (#"\bhf_[A-Za-z0-9]{30,}"#, "Hugging Face token"),
            (#"\bdop_v1_[a-f0-9]{60,}"#, "DigitalOcean token"),
        ]
        for (pattern, label) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return Finding(reason: label)
        }
        return nil
    }

    /// `PASSWORD = "value"` / `api_key: value` / `secret=value` — the common
    /// way a credential leaks inside otherwise-ordinary text (env files,
    /// config snippets). Needs a secret-y key name AND a non-trivial value.
    private static func credentialAssignment(_ text: String) -> Finding? {
        // Lookbehind for a non-alphanumeric so env-var style (DB_PASSWORD)
        // matches while a real word (mypassword) does not.
        let pattern = #"(?i)(?<![A-Za-z0-9])(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)\s*[:=]\s*["']?[^\s"']{8,}"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        // Don't trip on obvious placeholders.
        let lower = text.lowercased()
        for placeholder in ["your_", "xxxx", "<your", "example", "changeme", "placeholder", "•••", "****"] {
            if lower.contains(placeholder) { return nil }
        }
        return Finding(reason: "credential in text")
    }

    private static func privateKeyBlock(_ text: String) -> Finding? {
        text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
            ? Finding(reason: "private key") : nil
    }

    /// JWT: three dot-separated base64url segments, first decoding to `{"...`.
    private static func jwt(_ text: String) -> Finding? {
        guard text.range(of: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
                         options: .regularExpression) != nil else { return nil }
        return Finding(reason: "JWT token")
    }

    /// 13–19 digits (spaces/dashes allowed) passing Luhn, standing alone-ish.
    private static func paymentCard(_ text: String) -> Finding? {
        guard let range = text.range(of: #"\b(?:\d[ -]?){13,19}\b"#, options: .regularExpression)
        else { return nil }
        let digits = text[range].filter(\.isNumber).compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count), luhnValid(digits) else { return nil }
        return Finding(reason: "payment card number")
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0 && digits.count >= 13
    }

    /// IBAN with a valid mod-97 check.
    private static func iban(_ text: String) -> Finding? {
        guard let range = text.range(of: #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#,
                                     options: .regularExpression) else { return nil }
        let candidate = String(text[range])
        let rearranged = candidate.dropFirst(4) + candidate.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue, ch.isNumber { value = d }
            else if let ascii = ch.asciiValue, ch.isLetter { value = Int(ascii - 55) }
            else { return nil }
            remainder = value < 10 ? (remainder * 10 + value) % 97
                                   : (remainder * 100 + value) % 97
        }
        return remainder == 1 ? Finding(reason: "IBAN") : nil
    }

    /// A lone high-entropy token — the clipboard holding *just* a credential.
    /// Only fires when the whole clip is a single token, so prose containing a
    /// hash never trips it.
    private static func highEntropyToken(_ text: String) -> Finding? {
        guard text.count >= 24, text.count <= 128,
              !text.contains(where: \.isWhitespace),
              text.allSatisfy({ $0.isLetter || $0.isNumber || "+/=_-".contains($0) })
        else { return nil }
        // Needs digits AND both cases (or base64 padding) — filters words/slugs.
        let hasDigit = text.contains(where: \.isNumber)
        let hasLower = text.contains(where: \.isLowercase)
        let hasUpper = text.contains(where: \.isUppercase)
        guard hasDigit && hasLower && hasUpper else { return nil }
        guard shannonEntropy(text) > 4.2 else { return nil }
        return Finding(reason: "high-entropy token")
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}
