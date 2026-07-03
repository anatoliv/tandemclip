import XCTest
import NaturalLanguage
@testable import tandemclip

final class HelpSearchTests: XCTestCase {
    func testCatalogCoversEverySettingsTab() {
        let categories = Set(HelpCatalog.topics.map(\.category))
        for tab in ["General", "Sync", "Content", "AI", "Security"] {
            XCTAssertTrue(categories.contains("Settings — \(tab)"), "missing help for Settings → \(tab)")
        }
        // Every declared category has at least one topic, and vice versa.
        for cat in HelpCatalog.categories {
            XCTAssertFalse(HelpCatalog.topics(in: cat.name).isEmpty, "empty category \(cat.name)")
        }
        XCTAssertEqual(categories, Set(HelpCatalog.categories.map(\.name)))
    }

    func testSyncBehaviorHasWorkedExamplesForEveryCase() {
        let sync = HelpCatalog.topics(in: "Settings — Sync")
        let ids = Set(sync.map(\.id))
        for required in ["sync-mirror", "sync-manual", "sync-role-sendreceive", "sync-role-receiveonly",
                         "sync-role-sendonly", "sync-peer-preview", "sync-auto-apply", "sync-recipes"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
        // The mode/role/behavior topics carry practical examples, not just definitions.
        let mustHaveExamples = ["sync-mirror", "sync-manual", "sync-role-receiveonly",
                                "sync-role-sendonly", "sync-peer-preview", "sync-auto-apply"]
        for topic in sync where mustHaveExamples.contains(topic.id) {
            XCTAssertTrue(topic.body.contains("Example:"), "\(topic.id) lacks an example")
        }
    }

    func testKeywordSearchFindsExactTerms() {
        let results = HelpSearchModel.search("pairing", embedding: nil, vectors: [:])
        XCTAssertEqual(results.first?.id, "security-pairing")

        XCTAssertTrue(HelpSearchModel.search("quarantine", embedding: nil, vectors: [:])
            .contains { $0.id == "privacy-quarantine" })
        XCTAssertTrue(HelpSearchModel.search("x", embedding: nil, vectors: [:]).isEmpty,
                      "single characters shouldn't match anything")
    }

    func testSemanticSearchFindsParaphrases() throws {
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw XCTSkip("sentence embedding model unavailable on this machine")
        }
        var vectors: [String: [[Double]]] = [:]
        for t in HelpCatalog.topics {
            vectors[t.id] = HelpSearchModel.embeddingTexts(for: t).compactMap { emb.vector(for: $0) }
        }
        // Paraphrases with little/no keyword overlap — semantic must carry them.
        let missing = HelpSearchModel.search("my other computer does not show up",
                                             embedding: emb, vectors: vectors)
        XCTAssertTrue(missing.prefix(5).contains { $0.id == "ts-peer-missing" },
                      "computer≈Mac, show up≈appear — got \(missing.prefix(5).map(\.id))")

        let privacy = HelpSearchModel.search("hide what I copy from my other computers",
                                             embedding: emb, vectors: vectors)
        let acceptable: Set<String> = ["privacy-hold", "sync-peer-preview", "sync-role-receiveonly",
                                       "sync-role-sendonly", "privacy-passwords"]
        XCTAssertTrue(privacy.prefix(5).contains { acceptable.contains($0.id) },
                      "expected a privacy/visibility topic near the top, got \(privacy.prefix(5).map(\.id))")
    }

    func testCosine() {
        XCTAssertEqual(HelpSearchModel.cosine([1, 0], [1, 0]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(HelpSearchModel.cosine([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(HelpSearchModel.cosine([], []), 0.0)
    }
}
