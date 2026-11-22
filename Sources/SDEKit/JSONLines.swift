import Foundation
import CapsuleerCore

enum JSONLines {
    /// Decodes one `T` per non-blank line. Any bad line fails the whole decode.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL?) throws -> [T] {
        let decoder = JSONDecoder()
        var records: [T] = []
        var lineNumber = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            lineNumber += 1
            guard line.contains(where: { !Self.isWhitespace($0) }) else { continue }
            do {
                records.append(try decoder.decode(T.self, from: Data(line)))
            } catch {
                throw CapsuleerError(.decoding, message: "JSONL line \(lineNumber): \(error)", url: url, underlying: error)
            }
        }
        return records
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}
