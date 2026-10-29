import XCTest
@testable import WordSlide

final class DictionaryServiceTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        FixtureURLProtocol.handler = nil
        super.tearDown()
    }
    private func config(_ provider: DictionaryProvider = .oxford, chinese: Bool = false) -> LookupConfiguration {
        LookupConfiguration(provider: provider, oxfordAppID: "fixture-id", oxfordAppKey: "fixture-key", oxfordLanguage: "en-gb", oxfordChinese: chinese, collinsKey: "fixture-collins-key", collinsDictionary: "english")
    }
    private static func json(_ payload: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: payload) }
    private static let oxford: [String: Any] = [
        "results": [["id": "bank", "word": "bank", "lexicalEntries": [
            ["text": "bank", "lexicalCategory": ["text": "Noun"], "entries": [[
                "pronunciations": [["phoneticSpelling": "baŋk"]],
                "senses": [
                    ["definitions": ["A fixture financial institution.", "A second fixture definition."],
                     "examples": [["text": "I visited the fixture bank.", "translations": [["text": "我去了示例银行。"]]]],
                     "subsenses": [["definitions": ["A fixture building used by that institution."],
                                    "subsenses": [["definitions": ["A deeply nested fixture meaning."]]]]]],
                    ["definitions": ["A fixture river edge."]]
                ], "etymologies": ["Fixture origin."]
            ]]],
            ["text": "bank", "lexicalCategory": ["text": "Verb"], "entries": [["senses": [["definitions": ["To store in a fixture bank."]]]]]]
        ]]]
    ]

    func testEnglishWordNormalizationRejectsSentencesAndNonEnglish() {
        XCTAssertEqual(EnglishWord.normalize("  \"Hello!\"  "), "hello")
        XCTAssertEqual(EnglishWord.normalize("Don’t"), "don't")
        XCTAssertEqual(EnglishWord.normalize("state-of-the-art"), "state-of-the-art")
        XCTAssertNil(EnglishWord.normalize("hello world"))
        XCTAssertNil(EnglishWord.normalize("秘密"))
        XCTAssertNil(EnglishWord.normalize("user@example.com"))
        XCTAssertNil(EnglishWord.normalize("a\nb"))
        XCTAssertNil(EnglishWord.normalize(String(repeating: "a", count: 65)))
    }

    func testOxfordPreservesMultiplePartsOfSpeechAndDeepSubsenses() throws {
        let parsed = try DictionaryService.parseOxford(Self.oxford, headingPrefix: "英文")
        XCTAssertEqual(parsed.headwords, ["bank"])
        XCTAssertEqual(parsed.sections.count, 2)
        let body = parsed.sections.map(\.body).joined(separator: "\n")
        XCTAssertTrue(body.contains("A second fixture definition."))
        XCTAssertTrue(body.contains("1.1.1"))
        XCTAssertTrue(body.contains("A deeply nested fixture meaning."))
        XCTAssertTrue(body.contains("A fixture river edge."))
        XCTAssertTrue(body.contains("To store in a fixture bank."))
        XCTAssertTrue(body.contains("我去了示例银行。"))
        XCTAssertTrue(body.contains("Fixture origin."))
    }

    func testOxfordDoesNotTruncateLongEntry() throws {
        let senses: [[String: Any]] = (1...120).map { ["definitions": ["Fixture sense \($0)"]] }
        let payload: [String: Any] = ["results": [["word": "set", "lexicalEntries": [["text": "set", "entries": [["senses": senses]]]]]]]
        let parsed = try DictionaryService.parseOxford(payload, headingPrefix: "英文")
        XCTAssertTrue(parsed.sections[0].body.contains("Fixture sense 120"))
    }

    func testOxfordUsesWordsQueryAndKeepsEnglishIfChineseUnauthorized() async throws {
        var paths: [String] = []
        FixtureURLProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "app_id"), "fixture-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "app_key"), "fixture-key")
            if request.url!.path.contains("/words/") {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "bank")
                return (200, Self.json(Self.oxford))
            }
            return (403, Self.json(["error": "fixture denied"]))
        }
        let result = try await DictionaryService(session: session).lookup("BANK", configuration: config(chinese: true))
        XCTAssertEqual(paths, ["/api/v2/words/en-gb", "/api/v2/translations/en/zh/bank"])
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertTrue(result.notice?.contains("401/403") == true)
        XCTAssertTrue(result.notice?.contains("仅显示英文") == true)
    }

    func testOxfordSuccessfulChineseIncludesNestedTranslationsAndExamples() async throws {
        FixtureURLProtocol.handler = { request in
            if request.url!.path.contains("/words/") { return (200, Self.json(Self.oxford)) }
            return (200, Self.json(["results": [["word": "bank", "lexicalEntries": [["text": "bank", "entries": [["senses": [["translations": [["text": "银行"]], "subsenses": [["translations": [["text": "储备库"]]]]]]]]]]]]]))
        }
        let result = try await DictionaryService(session: session).lookup("bank", configuration: config(chinese: true))
        XCTAssertEqual(result.sections.count, 3)
        XCTAssertTrue(result.sections.last!.body.contains("银行"))
        XCTAssertTrue(result.sections.last!.body.contains("储备库"))
        XCTAssertNil(result.notice)
    }

    func testHTTPFailuresAreActionableAndDoNotFallBack() async {
        for (status, expected) in [(401, DictionaryLookupError.authentication), (403, .authentication), (404, .notFound), (429, .rateLimited), (503, .http(503))] {
            var calls = 0
            FixtureURLProtocol.handler = { _ in calls += 1; return (status, Data()) }
            do {
                _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
                XCTFail("Expected a mapped error")
            } catch {
                XCTAssertEqual(error as? DictionaryLookupError, expected)
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testMalformedPayloadAndNetworkTimeoutAreMapped() async {
        FixtureURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            XCTFail("Expected invalid response")
        } catch { XCTAssertEqual(error as? DictionaryLookupError, .invalidResponse) }
        FixtureURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DictionaryLookupError, .timeout) }
    }

    func testCancelledURLSessionDoesNotBecomeUserFacingNetworkError() async {
        FixtureURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingCredentialsNeverSendsNetworkRequest() async {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; return (200, Self.json(Self.oxford)) }
        var configuration = config()
        configuration.oxfordAppKey = ""
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: configuration)
            XCTFail("Expected missing credentials")
        } catch { XCTAssertEqual(calls, 0); XCTAssertNotNil(error as? DictionaryLookupError) }
    }

    func testCollinsFetchesAllExactHomographsAcrossPages() async throws {
        var entryPaths: [String] = []
        FixtureURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "accessKey"), "fixture-collins-key")
            if request.url!.path.hasSuffix("/search") {
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first(where: { $0.name == "pageindex" })!.value
                let results: [[String: Any]] = page == "1" ? [
                    ["entryLabel": "bank<sup>1</sup>", "entryId": "bank_1"],
                    ["entryLabel": "bank account", "entryId": "bank-account_1"]
                ] : [["entryLabel": "bank²", "entryId": "bank_2"]]
                return (200, Self.json(["pageNumber": 2, "results": results]))
            }
            entryPaths.append(request.url!.lastPathComponent)
            return (200, Self.json(["entryContent": "<div><h1>bank</h1><p>First fixture meaning.</p><p>Second fixture meaning.</p></div>"]))
        }
        let result = try await DictionaryService(session: session).lookup("bank", configuration: config(.collins))
        XCTAssertEqual(entryPaths, ["bank_1", "bank_2"])
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertTrue(result.sections.allSatisfy { $0.body.contains("Second fixture meaning.") })
    }

    func testCollinsDisclosesBoundedSearchRatherThanClaimingComplete() async throws {
        var searches = 0
        FixtureURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/search") {
                searches += 1
                return (200, Self.json(["pageNumber": 20, "results": [["entryLabel": "bank", "entryId": "bank_1"]]]))
            }
            return (200, Self.json(["entryContent": "<p>All fixture entry senses.</p>"]))
        }
        let result = try await DictionaryService(session: session).lookup("bank", configuration: config(.collins))
        XCTAssertEqual(searches, 5)
        XCTAssertTrue(result.notice?.contains("可能尚有其他") == true)
    }

    func testCollinsDoesNotSubstitutePrefixCompound() async {
        FixtureURLProtocol.handler = { _ in (200, Self.json(["pageNumber": 1, "results": [["entryLabel": "bank account", "entryId": "bank-account_1"]]])) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config(.collins))
            XCTFail("Should not return another headword")
        } catch { XCTAssertEqual(error as? DictionaryLookupError, .notFound) }
    }

    func testPlainHTMLNeverIncludesScriptOrStyleAndDecodesUnicode() {
        let html = "<div><h1>bank&nbsp;&amp;&nbsp;river</h1><script>bad()</script><style>.hidden{}</style><p>银行 &#x4E2D; &#20013; &theta; &rsquo;</p><img src='https://example.invalid/track'></div>"
        let text = PlainDictionaryHTML.text(html)
        XCTAssertTrue(text.contains("bank & river"))
        XCTAssertTrue(text.contains("银行 中 中 θ ’"))
        XCTAssertFalse(text.contains("bad()"))
        XCTAssertFalse(text.contains("hidden"))
        XCTAssertFalse(text.contains("track"))
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
