// Standalone fixture/assertion runner for Apple Command Line Tools.
// These scenarios mirror Tests/WordSlideTests, but this runner does not use XCTest.
// No production API credentials or external network services are used.
import Foundation

private final class FixtureSuite {
    private var session: URLSession!
    func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    func tearDown() {
        session.invalidateAndCancel()
        FixtureURLProtocol.handler = nil
    }
    private func config(_ provider: DictionaryProvider = .oxford, chinese: Bool = false) -> LookupConfiguration {
        LookupConfiguration(provider: provider, oxfordAppID: "fixture-id", oxfordAppKey: "fixture-key", oxfordLanguage: "en-gb", oxfordChinese: chinese, collinsKey: "fixture-collins-key", collinsDictionary: "english")
    }
    private static func json(_ payload: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: payload) }
    private static let oxford: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
    {
      "results": [{
        "id": "bank", "word": "bank", "lexicalEntries": [
          {"text": "bank", "lexicalCategory": {"text": "Noun"}, "entries": [{
            "pronunciations": [{"phoneticSpelling": "baŋk"}],
            "senses": [
              {"definitions": ["A fixture financial institution.", "A second fixture definition."],
               "examples": [{"text": "I visited the fixture bank.", "translations": [{"text": "我去了示例银行。"}]}],
               "subsenses": [{"definitions": ["A fixture building used by that institution."],
                              "subsenses": [{"definitions": ["A deeply nested fixture meaning."]}]}]},
              {"definitions": ["A fixture river edge."]}
            ], "etymologies": ["Fixture origin."]
          }]},
          {"text": "bank", "lexicalCategory": {"text": "Verb"}, "entries": [{
            "senses": [{"definitions": ["To store in a fixture bank."]}]
          }]}
        ]
      }]
    }
    """#.utf8)) as! [String: Any]

    func testEnglishWordNormalizationRejectsSentencesAndNonEnglish() {
        checkEqual(EnglishWord.normalize("  \"Hello!\"  "), "hello")
        checkEqual(EnglishWord.normalize("Don’t"), "don't")
        checkEqual(EnglishWord.normalize("state-of-the-art"), "state-of-the-art")
        checkNil(EnglishWord.normalize("hello world"))
        checkNil(EnglishWord.normalize("秘密"))
        checkNil(EnglishWord.normalize("user@example.com"))
        checkNil(EnglishWord.normalize("a\nb"))
        checkNil(EnglishWord.normalize(String(repeating: "a", count: 65)))
    }

    func testOxfordPreservesMultiplePartsOfSpeechAndDeepSubsenses() throws {
        let parsed = try DictionaryService.parseOxford(Self.oxford, headingPrefix: "英文")
        checkEqual(parsed.headwords, ["bank"])
        checkEqual(parsed.sections.count, 2)
        let body = parsed.sections.map(\.body).joined(separator: "\n")
        checkTrue(body.contains("A second fixture definition."))
        checkTrue(body.contains("1.1.1"))
        checkTrue(body.contains("A deeply nested fixture meaning."))
        checkTrue(body.contains("A fixture river edge."))
        checkTrue(body.contains("To store in a fixture bank."))
        checkTrue(body.contains("我去了示例银行。"))
        checkTrue(body.contains("Fixture origin."))
    }

    func testOxfordDoesNotTruncateLongEntry() throws {
        let senses: [[String: Any]] = (1...120).map { ["definitions": ["Fixture sense \($0)"]] }
        let entry: [String: Any] = ["senses": senses]
        let lexical: [String: Any] = ["text": "set", "entries": [entry]]
        let result: [String: Any] = ["word": "set", "lexicalEntries": [lexical]]
        let payload: [String: Any] = ["results": [result]]
        let parsed = try DictionaryService.parseOxford(payload, headingPrefix: "英文")
        checkTrue(parsed.sections[0].body.contains("Fixture sense 120"))
    }

    func testOxfordUsesWordsQueryAndKeepsEnglishIfChineseUnauthorized() async throws {
        var paths: [String] = []
        FixtureURLProtocol.handler = { request in
            paths.append(request.url!.path)
            checkEqual(request.value(forHTTPHeaderField: "app_id"), "fixture-id")
            checkEqual(request.value(forHTTPHeaderField: "app_key"), "fixture-key")
            if request.url!.path.contains("/words/") {
                checkEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "bank")
                return (200, Self.json(Self.oxford))
            }
            return (403, Self.json(["error": "fixture denied"]))
        }
        let result = try await DictionaryService(session: session).lookup("BANK", configuration: config(chinese: true))
        checkEqual(paths, ["/api/v2/words/en-gb", "/api/v2/translations/en/zh/bank"])
        checkEqual(result.sections.count, 2)
        checkTrue(result.notice?.contains("401/403") == true)
        checkTrue(result.notice?.contains("仅显示英文") == true)
    }

    func testOxfordSuccessfulChineseIncludesNestedTranslationsAndExamples() async throws {
        FixtureURLProtocol.handler = { request in
            if request.url!.path.contains("/words/") { return (200, Self.json(Self.oxford)) }
            let nested: [String: Any] = ["translations": [["text": "储备库"]]]
            let sense: [String: Any] = ["translations": [["text": "银行"]], "subsenses": [nested]]
            let entry: [String: Any] = ["senses": [sense]]
            let lexical: [String: Any] = ["text": "bank", "entries": [entry]]
            let result: [String: Any] = ["word": "bank", "lexicalEntries": [lexical]]
            return (200, Self.json(["results": [result]]))
        }
        let result = try await DictionaryService(session: session).lookup("bank", configuration: config(chinese: true))
        checkEqual(result.sections.count, 3)
        checkTrue(result.sections.last!.body.contains("银行"))
        checkTrue(result.sections.last!.body.contains("储备库"))
        checkNil(result.notice)
    }

    func testHTTPFailuresAreActionableAndDoNotFallBack() async {
        for (status, expected) in [(401, DictionaryLookupError.authentication), (403, .authentication), (404, .notFound), (429, .rateLimited), (503, .http(503))] {
            var calls = 0
            FixtureURLProtocol.handler = { _ in calls += 1; return (status, Data()) }
            do {
                _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
                checkFailure("Expected a mapped error")
            } catch {
                checkEqual(error as? DictionaryLookupError, expected)
                checkEqual(calls, 1)
            }
        }
    }

    func testMalformedPayloadAndNetworkTimeoutAreMapped() async {
        FixtureURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            checkFailure("Expected invalid response")
        } catch { checkEqual(error as? DictionaryLookupError, .invalidResponse) }
        FixtureURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            checkFailure("Expected timeout")
        } catch { checkEqual(error as? DictionaryLookupError, .timeout) }
    }

    func testCancelledURLSessionDoesNotBecomeUserFacingNetworkError() async {
        FixtureURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config())
            checkFailure("Expected cancellation")
        } catch { checkTrue(error is CancellationError) }
    }

    func testMissingCredentialsNeverSendsNetworkRequest() async {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; return (200, Self.json(Self.oxford)) }
        var configuration = config()
        configuration.oxfordAppKey = ""
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: configuration)
            checkFailure("Expected missing credentials")
        } catch { checkEqual(calls, 0); checkNotNil(error as? DictionaryLookupError) }
    }

    func testCollinsFetchesAllExactHomographsAcrossPages() async throws {
        var entryPaths: [String] = []
        FixtureURLProtocol.handler = { request in
            checkEqual(request.value(forHTTPHeaderField: "accessKey"), "fixture-collins-key")
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
        checkEqual(entryPaths, ["bank_1", "bank_2"])
        checkEqual(result.sections.count, 2)
        checkTrue(result.sections.allSatisfy { $0.body.contains("Second fixture meaning.") })
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
        checkEqual(searches, 5)
        checkTrue(result.notice?.contains("可能尚有其他") == true)
    }

    func testCollinsDoesNotSubstitutePrefixCompound() async {
        FixtureURLProtocol.handler = { _ in (200, Self.json(["pageNumber": 1, "results": [["entryLabel": "bank account", "entryId": "bank-account_1"]]])) }
        do {
            _ = try await DictionaryService(session: session).lookup("bank", configuration: config(.collins))
            checkFailure("Should not return another headword")
        } catch { checkEqual(error as? DictionaryLookupError, .notFound) }
    }

    func testPlainHTMLNeverIncludesScriptOrStyleAndDecodesUnicode() {
        let html = "<div><h1>bank&nbsp;&amp;&nbsp;river</h1><script>bad()</script><style>.hidden{}</style><p>银行 &#x4E2D; &#20013; &theta; &rsquo;</p><img src='https://example.invalid/track'></div>"
        let text = PlainDictionaryHTML.text(html)
        checkTrue(text.contains("bank & river"))
        checkTrue(text.contains("银行 中 中 θ ’"))
        checkFalse(text.contains("bad()"))
        checkFalse(text.contains("hidden"))
        checkFalse(text.contains("track"))
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

private enum Checks {
    private static let lock = NSLock()
    private static var failureCount = 0
    private static var assertionCount = 0
    static var failures: Int { lock.lock(); defer { lock.unlock() }; return failureCount }
    static var assertions: Int { lock.lock(); defer { lock.unlock() }; return assertionCount }
    static func record(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
        lock.lock()
        assertionCount += 1
        if !passed { failureCount += 1 }
        lock.unlock()
        if !passed { print("  Assertion failed: \(message) (\(file):\(line))") }
    }
}
private func checkEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                                       _ message: String = "Values differ", file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(actual() == expected(), message, file: file, line: line)
}
private func checkTrue(_ actual: @autoclosure () -> Bool, _ message: String = "Expected true",
                       file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(actual(), message, file: file, line: line)
}
private func checkFalse(_ actual: @autoclosure () -> Bool, _ message: String = "Expected false",
                        file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(!actual(), message, file: file, line: line)
}
private func checkNil<T>(_ actual: @autoclosure () -> T?, _ message: String = "Expected nil",
                         file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(actual() == nil, message, file: file, line: line)
}
private func checkNotNil<T>(_ actual: @autoclosure () -> T?, _ message: String = "Expected non-nil",
                            file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(actual() != nil, message, file: file, line: line)
}
private func checkFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Checks.record(false, message, file: file, line: line)
}

@main private struct SmokeTests {
    static func main() async {
        print("WordSlide standalone fixture/assertion tests (Command Line Tools; no XCTest)")
        let suite = FixtureSuite()
        let cases: [(String, () async throws -> Void)] = [
            ("testEnglishWordNormalizationRejectsSentencesAndNonEnglish", { suite.testEnglishWordNormalizationRejectsSentencesAndNonEnglish() }),
            ("testOxfordPreservesMultiplePartsOfSpeechAndDeepSubsenses", { try suite.testOxfordPreservesMultiplePartsOfSpeechAndDeepSubsenses() }),
            ("testOxfordDoesNotTruncateLongEntry", { try suite.testOxfordDoesNotTruncateLongEntry() }),
            ("testOxfordUsesWordsQueryAndKeepsEnglishIfChineseUnauthorized", { try await suite.testOxfordUsesWordsQueryAndKeepsEnglishIfChineseUnauthorized() }),
            ("testOxfordSuccessfulChineseIncludesNestedTranslationsAndExamples", { try await suite.testOxfordSuccessfulChineseIncludesNestedTranslationsAndExamples() }),
            ("testHTTPFailuresAreActionableAndDoNotFallBack", { await suite.testHTTPFailuresAreActionableAndDoNotFallBack() }),
            ("testMalformedPayloadAndNetworkTimeoutAreMapped", { await suite.testMalformedPayloadAndNetworkTimeoutAreMapped() }),
            ("testCancelledURLSessionDoesNotBecomeUserFacingNetworkError", { await suite.testCancelledURLSessionDoesNotBecomeUserFacingNetworkError() }),
            ("testMissingCredentialsNeverSendsNetworkRequest", { await suite.testMissingCredentialsNeverSendsNetworkRequest() }),
            ("testCollinsFetchesAllExactHomographsAcrossPages", { try await suite.testCollinsFetchesAllExactHomographsAcrossPages() }),
            ("testCollinsDisclosesBoundedSearchRatherThanClaimingComplete", { try await suite.testCollinsDisclosesBoundedSearchRatherThanClaimingComplete() }),
            ("testCollinsDoesNotSubstitutePrefixCompound", { await suite.testCollinsDoesNotSubstitutePrefixCompound() }),
            ("testPlainHTMLNeverIncludesScriptOrStyleAndDecodesUnicode", { suite.testPlainHTMLNeverIncludesScriptOrStyleAndDecodesUnicode() }),
        ]
        var failedTests = 0
        for (name, run) in cases {
            suite.setUp()
            let before = Checks.failures
            do { try await run() }
            catch { checkFailure("Unexpected error in \(name): \(error)") }
            suite.tearDown()
            if Checks.failures == before { print("PASS \(name)") }
            else { failedTests += 1; print("FAIL \(name)") }
        }
        print("\(cases.count) fixture tests, \(Checks.assertions) assertions, \(failedTests) failed tests.")
        if failedTests > 0 { exit(1) }
    }
}
