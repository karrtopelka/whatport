import Foundation

/// Splits a command line into words the way a POSIX shell would (quotes and
/// backslash escapes), without ever invoking a shell. Used only to turn text
/// the user typed into an argument vector.
enum ShellWords {
    enum Failure: Error, LocalizedError, Equatable {
        case unterminatedQuote

        var errorDescription: String? { "Unterminated quote in command." }
    }

    static func split(_ input: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                hasWord = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" && activeQuote == "\"" {
                    escaping = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\\":
                escaping = true
                hasWord = true
            case "\"", "'":
                quote = character
                hasWord = true
            case " ", "\t", "\n":
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
            default:
                current.append(character)
                hasWord = true
            }
        }
        if quote != nil || escaping { throw Failure.unterminatedQuote }
        if hasWord { words.append(current) }
        return words
    }

    static func quoteIfNeeded(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ words: [String]) -> String {
        words.map(quoteIfNeeded).joined(separator: " ")
    }
}
