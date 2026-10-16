import Foundation
import SwiftData
import Observation

// MARK: - Card data (from YGOPRODeck API)

struct Card: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let type: String
    let desc: String
    let atk: Int?
    let def: Int?
    let level: Int?
    let linkval: Int?
    let race: String?
    let attribute: String?
    let card_images: [Art]?
    let card_sets: [CardSet]?

    struct Art: Codable, Hashable {
        let image_url: String
        let image_url_small: String?
    }

    struct CardSet: Codable, Hashable {
        let set_name: String
        let set_code: String
        let set_rarity: String?
    }

    /// "Legend of Blue Eyes White Dragon · Ultra Rare / Common" for a printed set code, if known.
    func setLabel(for code: String) -> String? {
        let rows = (card_sets ?? []).filter { $0.set_code.uppercased() == code.uppercased() }
        guard let first = rows.first else { return nil }
        let rarities = rows.compactMap(\.set_rarity).joined(separator: " / ")
        return rarities.isEmpty ? first.set_name : "\(first.set_name) · \(rarities)"
    }

    var imageURL: URL? { card_images?.first.flatMap { URL(string: $0.image_url) } }
    var smallURL: URL? { card_images?.first.flatMap { URL(string: $0.image_url_small ?? $0.image_url) } }
    var isExtraDeck: Bool { ["Fusion", "Synchro", "XYZ", "Link"].contains { type.contains($0) } }
}

/// Downloads the full card list once, caches it on disk, and matches scanned text to cards offline.
@Observable
final class CardDB {
    static let shared = CardDB()

    private(set) var cards: [Int: Card] = [:]
    @ObservationIgnored private var byName: [String: Card] = [:]
    @ObservationIgnored private var keys: [([UInt32], Card)] = []
    @ObservationIgnored private var fuzzyCache: [String: Int] = [:]   // normalized text -> card id (0 = no match)
    @ObservationIgnored private var bySetCode: [String: Card] = [:]   // "LOB-EN001" -> card
    @ObservationIgnored private var bySetKey: [String: Card] = [:]    // region-free "LOB001" -> card (matches any language)
    var isLoading = false
    var error: String?

    private struct Response: Codable { let data: [Card] }
    private var fileURL: URL { URL.documentsDirectory.appending(path: "cards.json") }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func match(_ text: String) -> Card? { byName[Self.normalize(text)] }

    /// Exact match first; otherwise the closest card name within a small edit distance,
    /// accepted only if it is the single best candidate (so ambiguous OCR never guesses).
    func fuzzyMatch(_ text: String) -> Card? {
        let q = Self.normalize(text)
        if let c = byName[q] { return c }
        guard q.count >= 6 else { return nil }          // too short to fuzzy-match safely
        if let id = fuzzyCache[q] { return id == 0 ? nil : cards[id] }

        let limit = q.count < 10 ? 1 : (q.count < 16 ? 2 : 3)
        let qa = q.unicodeScalars.map { $0.value }
        var best = Int.max, second = Int.max
        var bestCard: Card?
        for (k, card) in keys where abs(k.count - qa.count) <= limit {
            let d = Self.distance(qa, k, cap: limit)
            if d > limit { continue }
            if d < best { second = best; best = d; bestCard = card }
            else if d < second { second = d }
        }
        let result = (best <= limit && second > best) ? bestCard : nil
        if fuzzyCache.count > 2000 { fuzzyCache.removeAll() }
        fuzzyCache[q] = result?.id ?? 0
        return result
    }

    // MARK: Set codes (e.g. LOB-EN001, SDK-001, LDK2-ENK01)

    private static let codeRE = try! NSRegularExpression(pattern: "^([A-Z0-9]{2,5})-([A-Z]{0,2})([A-Z]?[0-9]{2,3})$")

    /// Splits a set code into set prefix, language region, and card number.
    private static func split(_ code: String) -> (prefix: String, region: String, tail: String)? {
        let ns = code as NSString
        guard let m = codeRE.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3)))
    }

    /// Fixes common OCR slips in the number part (O->0, I/L->1).
    private static func fixDigits(_ s: String) -> String {
        let map: [Character: Character] = ["O": "0", "I": "1", "L": "1"]
        let n = s.count
        return String(s.enumerated().map { $0.offset >= n - 3 ? (map[$0.element] ?? $0.element) : $0.element })
    }

    /// Finds a printed set code in a line of OCR text. Works for any language region
    /// (a German LOB-DE001 still resolves to the right card) and returns the code as read.
    func setCodeMatch(_ text: String) -> (card: Card, code: String)? {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "[–—−]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\\s*-\\s*", with: "-", options: .regularExpression)
        for raw in cleaned.split(whereSeparator: \.isWhitespace) {
            let token = String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            guard token.contains("-") else { continue }
            for code in [token, Self.fixDigits(token)] {
                if let card = bySetCode[code] { return (card, code) }
                if let p = Self.split(code), let card = bySetKey[p.prefix + p.tail] { return (card, code) }
            }
        }
        return nil
    }

    /// Levenshtein distance with early exit once it must exceed `cap`.
    private static func distance(_ a: [UInt32], _ b: [UInt32], cap: Int) -> Int {
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    @MainActor
    func load() async {
        guard cards.isEmpty, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            var data = try? Data(contentsOf: fileURL)
            if data == nil {
                let url = URL(string: "https://db.ygoprodeck.com/api/v7/cardinfo.php")!
                let (d, _) = try await URLSession.shared.data(from: url)
                try d.write(to: fileURL)
                data = d
            }
            let payload = data!
            let list = try await Task.detached { try JSONDecoder().decode(Response.self, from: payload).data }.value
            cards = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            byName = Dictionary(list.map { (Self.normalize($0.name), $0) }, uniquingKeysWith: { a, _ in a })
            keys = byName.compactMap { key, card in
                key.isEmpty ? nil : (key.unicodeScalars.map { $0.value }, card)
            }
            fuzzyCache.removeAll()
            bySetCode.removeAll()
            bySetKey.removeAll()
            for card in list {
                for s in card.card_sets ?? [] {
                    let code = s.set_code.uppercased()
                    if bySetCode[code] == nil { bySetCode[code] = card }
                    if let p = Self.split(code), bySetKey[p.prefix + p.tail] == nil {
                        bySetKey[p.prefix + p.tail] = card
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)   // retry fresh next launch
            self.error = "Couldn't load card database: \(error.localizedDescription)"
        }
    }
}

// MARK: - Persistence (SwiftData)

@Model
final class OwnedCard {
    @Attribute(.unique) var cardID: Int
    var quantity: Int
    var added: Date
    var printings: [String] = []   // set codes read from scanned copies, e.g. "LOB-EN001"

    init(cardID: Int, quantity: Int = 1) {
        self.cardID = cardID
        self.quantity = quantity
        self.added = .now
    }
}

@Model
final class Deck {
    var name: String
    var cardIDs: [Int]   // one entry per copy

    init(name: String) {
        self.name = name
        self.cardIDs = []
    }
}

/// "LOB-EN001 ×2, SDK-001" — compact summary of scanned printings.
func printingsSummary(_ codes: [String]) -> String {
    Dictionary(grouping: codes, by: { $0 })
        .sorted { $0.key < $1.key }
        .map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }
        .joined(separator: ", ")
}
