import Foundation
import CoreServices

/// Dictionary content stays in memory. The default session has no disk cache or cookies.
actor DictionaryService {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 18
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: DictionaryRedirectPolicy(), delegateQueue: nil)
        }
    }

    func lookup(_ input: String, configuration: LookupConfiguration) async throws -> DictionaryResult {
        guard let word = EnglishWord.normalize(input) else { throw DictionaryLookupError.invalidWord }
        try Task.checkCancellation()
        switch configuration.provider {
        case .system: return try Self.localLookup(word)
        case .oxford: return try await oxfordLookup(word, configuration)
        case .collins: return try await collinsLookup(word, configuration)
        }
    }

    private static func localLookup(_ word: String) throws -> DictionaryResult {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?,
              !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictionaryLookupError.localDictionaryUnavailable
        }
        return DictionaryResult(
            word: word, source: "macOS 本地词典",
            sections: [DictionarySection(heading: "词典释义", body: definition)],
            notice: "内容由 macOS 当前启用词典返回；系统接口仅返回首个匹配词条。需要中文时，请在「词典」App 的设置中下载英汉词典并调整顺序。",
            sourceURL: URL(string: "dict://" + word)
        )
    }

    // Official API: https://developer.oxforddictionaries.com/lexical-data-api
    // Words accepts inflected forms; Translations accepts headwords, source en and target zh.
    private func oxfordLookup(_ word: String, _ configuration: LookupConfiguration) async throws -> DictionaryResult {
        guard !configuration.oxfordAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.oxfordAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictionaryLookupError.missingCredentials("请在设置中填写 Oxford App ID 和 App Key。")
        }
        let language = configuration.oxfordLanguage == "en-us" ? "en-us" : "en-gb"
        let headers = ["app_id": configuration.oxfordAppID, "app_key": configuration.oxfordAppKey]
        let payload = try await getJSON(url: Self.url(host: "od-api.oxforddictionaries.com", path: ["api", "v2", "words", language], query: [URLQueryItem(name: "q", value: word)]), headers: headers)
        let parsed = try Self.parseOxford(payload, headingPrefix: "英文")
        var sections = parsed.sections
        var notices: [String] = []
        if configuration.oxfordChinese {
            var translated = false
            for headword in parsed.headwords.isEmpty ? [word] : parsed.headwords {
                try Task.checkCancellation()
                do {
                    let chinese = try await getJSON(url: Self.url(host: "od-api.oxforddictionaries.com", path: ["api", "v2", "translations", "en", "zh", headword]), headers: headers)
                    sections += try Self.parseOxford(chinese, headingPrefix: "英汉").sections
                    translated = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "暂时无法获取英汉释义。"
                    notices.append("\(headword) 的英汉部分未返回：\(reason)")
                }
            }
            if !translated { notices.append("当前仅显示英文释义；英汉数据需要账号具有 Translations 英汉词库权限。") }
        } else {
            notices.append("当前为英文词典；可在设置中启用 Oxford 英汉翻译（需要相应词库权限）。")
        }
        return DictionaryResult(word: word, source: "Oxford Dictionaries · Oxford University Press", sections: sections,
                                notice: notices.isEmpty ? nil : notices.joined(separator: "\n"),
                                sourceURL: URL(string: "https://developer.oxforddictionaries.com/"))
    }

    // Official API: https://api.collinsdictionary.com/api/v1/documentation/html
    private func collinsLookup(_ word: String, _ configuration: LookupConfiguration) async throws -> DictionaryResult {
        guard !configuration.collinsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictionaryLookupError.missingCredentials("请在设置中填写 Collins Access Key，并选择账号已授权的词库代码。")
        }
        let code = configuration.collinsDictionary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw DictionaryLookupError.missingCredentials("Collins 词库代码只能包含字母、数字、连字符和下划线；请填写账号已授权的代码。")
        }
        let headers = ["accessKey": configuration.collinsKey]
        let base = ["api", "v1", "dictionaries", code]
        var matches: [(id: String, label: String)] = []
        var page = 1
        var morePages = true
        var partial = false
        // A word can have several homographs. Search pages contain compounds too; only exact
        // headword matches are fetched. Bound API usage and explicitly disclose any partial result.
        while morePages && page <= 5 {
            try Task.checkCancellation()
            let payload = try await getJSON(url: Self.url(host: "api.collinsdictionary.com", path: base + ["search"], query: [
                URLQueryItem(name: "q", value: word), URLQueryItem(name: "pagesize", value: "100"),
                URLQueryItem(name: "pageindex", value: String(page))
            ]), headers: headers)
            guard let results = payload["results"] as? [[String: Any]] else { throw DictionaryLookupError.invalidResponse }
            for result in results {
                guard let id = result["entryId"] as? String, let label = result["entryLabel"] as? String else { continue }
                if Self.collinsLabelMatches(label, word: word), !matches.contains(where: { $0.id == id }) {
                    matches.append((id, PlainDictionaryHTML.text(label)))
                }
            }
            if let pageNumber = payload["pageNumber"] as? Int {
                morePages = page < pageNumber
            } else if let count = payload["resultNumber"] as? Int {
                morePages = page * 100 < count
            } else {
                morePages = results.count == 100
            }
            page += 1
        }
        partial = morePages
        guard !matches.isEmpty else {
            if partial { throw DictionaryLookupError.searchLimit }
            throw DictionaryLookupError.notFound
        }
        var sections: [DictionarySection] = []
        // Each matched full entry includes all senses and examples available in the licensed dataset.
        for match in matches {
            try Task.checkCancellation()
            let payload = try await getJSON(url: Self.url(host: "api.collinsdictionary.com", path: base + ["entries", match.id], query: [URLQueryItem(name: "format", value: "html")]), headers: headers)
            sections.append(try Self.parseCollinsEntry(payload, label: match.label))
        }
        var notices = ["显示词库 \(code) 的匹配词条。中文释义取决于该词库是否为英汉词库；英文词库仅返回英文释义。"]
        if partial { notices.append("搜索结果超过 5 页，为控制接口用量，只显示前 5 页中匹配的词条，可能尚有其他同形词条。每个已加载词条的释义均完整显示。") }
        return DictionaryResult(word: word, source: "Collins Dictionary · HarperCollins", sections: sections,
                                notice: notices.joined(separator: "\n"), sourceURL: URL(string: "https://www.collinsdictionary.com/"))
    }

    private func getJSON(url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WordSlide/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw DictionaryLookupError.timeout }
            throw DictionaryLookupError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DictionaryLookupError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw DictionaryLookupError.authentication
        case 404: throw DictionaryLookupError.notFound
        case 429: throw DictionaryLookupError.rateLimited
        default: throw DictionaryLookupError.http(http.statusCode)
        }
        // Refuse unreasonable/incorrect payloads, without silently truncating a valid entry.
        guard data.count <= 8 * 1024 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DictionaryLookupError.invalidResponse
        }
        return payload
    }

    private static func url(host: String, path: [String], query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    static func collinsLabelMatches(_ label: String, word: String) -> Bool {
        let plain = PlainDictionaryHTML.text(label)
        let head = plain.replacingOccurrences(of: "[\\s0-9¹²³⁴⁵⁶⁷⁸⁹⁰]+$", with: "", options: .regularExpression)
        return EnglishWord.normalize(head) == word
    }

    static func parseCollinsEntry(_ payload: [String: Any], label: String) throws -> DictionarySection {
        guard let html = payload["entryContent"] as? String else { throw DictionaryLookupError.invalidResponse }
        let text = PlainDictionaryHTML.text(html)
        guard !text.isEmpty else { throw DictionaryLookupError.notFound }
        return DictionarySection(heading: label, body: text)
    }

    static func parseOxford(_ payload: [String: Any], headingPrefix: String) throws -> (sections: [DictionarySection], headwords: [String]) {
        guard let results = payload["results"] as? [[String: Any]], !results.isEmpty else { throw DictionaryLookupError.notFound }
        var sections: [DictionarySection] = []
        var headwords: [String] = []
        for result in results {
            let headword = (result["word"] as? String) ?? (result["id"] as? String) ?? ""
            if let normalized = EnglishWord.normalize(headword), !headwords.contains(normalized) { headwords.append(normalized) }
            for lexical in objects(result, "lexicalEntries") {
                let text = (lexical["text"] as? String) ?? headword
                let category = (lexical["lexicalCategory"] as? [String: Any])?["text"] as? String ?? ""
                var lines = metadata(lexical)
                appendReferences(lexical, "phrases", label: "短语", to: &lines)
                appendReferences(lexical, "phrasalVerbs", label: "短语动词", to: &lines)
                appendReferences(lexical, "derivatives", label: "派生词", to: &lines)
                appendReferences(lexical, "derivativeOf", label: "派生自", to: &lines)
                for (entryIndex, entry) in objects(lexical, "entries").enumerated() {
                    if let homograph = entry["homographNumber"] as? String { lines.append("同形词 \(homograph)") }
                    else if objects(lexical, "entries").count > 1 { lines.append("词条 \(entryIndex + 1)") }
                    lines += metadata(entry)
                    if let etymologies = entry["etymologies"] as? [String], !etymologies.isEmpty { lines.append("词源：" + etymologies.joined(separator: "；")) }
                    for (index, sense) in objects(entry, "senses").enumerated() { appendSense(sense, number: String(index + 1), to: &lines) }
                }
                // Some datasets put senses directly on the lexical entry.
                for (index, sense) in objects(lexical, "senses").enumerated() { appendSense(sense, number: String(index + 1), to: &lines) }
                if !lines.isEmpty {
                    sections.append(DictionarySection(heading: [headingPrefix, text, category].filter { !$0.isEmpty }.joined(separator: " · "), body: lines.joined(separator: "\n\n")))
                }
            }
        }
        guard !sections.isEmpty else { throw DictionaryLookupError.notFound }
        return (sections, headwords)
    }

    private static func appendSense(_ sense: [String: Any], number: String, to lines: inout [String]) {
        let definitions = sense["definitions"] as? [String] ?? sense["shortDefinitions"] as? [String] ?? []
        let labels = ["domains", "registers", "regions"].flatMap { objects(sense, $0).compactMap { $0["text"] as? String } }
        let heading = number + (labels.isEmpty ? "" : " [" + labels.joined(separator: " / ") + "]")
        lines.append(heading + (definitions.isEmpty ? "" : "  " + definitions.joined(separator: "；")))
        let translations = objects(sense, "translations").compactMap { translation -> String? in
            guard let text = translation["text"] as? String else { return nil }
            let labels = ["domains", "registers", "regions"].flatMap { objects(translation, $0).compactMap { $0["text"] as? String } }
            return text + (labels.isEmpty ? "" : "（" + labels.joined(separator: " / ") + "）")
        }
        if !translations.isEmpty { lines.append("中文：" + translations.joined(separator: "；")) }
        for example in objects(sense, "examples") {
            if let text = example["text"] as? String { lines.append("例：" + text) }
            for translation in objects(example, "translations") { if let text = translation["text"] as? String { lines.append("译：" + text) } }
        }
        for note in objects(sense, "notes") { if let text = note["text"] as? String { lines.append("注：" + text) } }
        appendReferences(sense, "crossReferences", label: "参见", to: &lines)
        appendReferences(sense, "synonyms", label: "近义词", to: &lines)
        appendReferences(sense, "antonyms", label: "反义词", to: &lines)
        appendReferences(sense, "variantForms", label: "变体", to: &lines)
        appendReferences(sense, "constructions", label: "用法", to: &lines)
        for (index, child) in objects(sense, "subsenses").enumerated() { appendSense(child, number: number + "." + String(index + 1), to: &lines) }
    }

    private static func metadata(_ object: [String: Any]) -> [String] {
        var lines: [String] = []
        let pronunciations = objects(object, "pronunciations").compactMap { item -> String? in
            guard let spelling = item["phoneticSpelling"] as? String else { return nil }
            let region = objects(item, "regions").compactMap { $0["text"] as? String }.joined(separator: ", ")
            return "/\(spelling)/" + (region.isEmpty ? "" : " (\(region))")
        }
        if !pronunciations.isEmpty { lines.append(pronunciations.joined(separator: "  ")) }
        let grammar = objects(object, "grammaticalFeatures").compactMap { $0["text"] as? String }
        if !grammar.isEmpty { lines.append(grammar.joined(separator: " / ")) }
        appendReferences(object, "variantForms", label: "变体", to: &lines)
        for note in objects(object, "notes") { if let text = note["text"] as? String { lines.append("注：" + text) } }
        return lines
    }

    private static func appendReferences(_ object: [String: Any], _ key: String, label: String, to lines: inout [String]) {
        let values = objects(object, key).compactMap { $0["text"] as? String }
        if !values.isEmpty { lines.append(label + "：" + values.joined(separator: "；")) }
    }

    private static func objects(_ object: [String: Any], _ key: String) -> [[String: Any]] { object[key] as? [[String: Any]] ?? [] }
}

enum DictionaryLookupError: LocalizedError, Equatable {
    case invalidWord, missingCredentials(String), localDictionaryUnavailable, authentication, notFound
    case rateLimited, invalidResponse, network, timeout, searchLimit, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidWord: return "请选择一个英文单词；支持连字符和英文缩写，不支持整句或段落。"
        case .missingCredentials(let message): return message
        case .localDictionaryUnavailable: return "本地词典未找到此词。请打开 macOS「词典」App，下载并启用英文或英汉词典；也可在设置中配置 Oxford / Collins API。"
        case .authentication: return "接口拒绝访问（401/403）。请检查密钥、套餐及所选词库的授权。"
        case .notFound: return "当前词库未找到此词条，或该词库代码不可用。"
        case .rateLimited: return "词典接口调用已达限额（429）；请稍后重试或检查套餐。"
        case .invalidResponse: return "词典返回了无法解析或过大的数据，请稍后重试。"
        case .network: return "无法连接词典接口，请检查网络连接。"
        case .timeout: return "词典接口响应超时，请稍后重试。"
        case .searchLimit: return "搜索结果过多，前 5 页中未找到准确词条；为控制接口用量已停止。请使用另一词库。"
        case .http(let code): return "词典服务暂时不可用（HTTP \(code)），请稍后重试。"
        }
    }
}

/// Never forward API credentials to another host or downgrade HTTPS on redirects.
private final class DictionaryRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Plain-text conversion only: no web renderer, script execution or external resource loading.
enum PlainDictionaryHTML {
    static func text(_ input: String) -> String {
        var value = input.replacingOccurrences(of: "(?is)<(script|style|noscript|iframe|object|svg)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)</?(?:div|p|h[1-6]|br|li|tr|table|section|article|dl|dt|dd|ul|ol)\\b[^>]*>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]+);")
        let original = value as NSString
        for match in regex.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            let key = original.substring(with: match.range(at: 1))
            let replacement: String?
            if key.hasPrefix("#x") { replacement = UInt32(key.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init) }
            else if key.hasPrefix("#") { replacement = UInt32(key.dropFirst()).flatMap(UnicodeScalar.init).map(String.init) }
            else { replacement = entities[key] }
            if let replacement = replacement, let range = Range(match.range, in: value) { value.replaceSubrange(range, with: replacement) }
        }
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[\\t \\u00a0]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let entities: [String: String] = [
        "amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" ",
        "ndash":"–", "mdash":"—", "lsquo":"‘", "rsquo":"’", "ldquo":"“", "rdquo":"”", "hellip":"…",
        "bull":"•", "middot":"·", "copy":"©", "reg":"®", "trade":"™", "deg":"°", "times":"×", "divide":"÷",
        "pound":"£", "euro":"€", "cent":"¢", "yen":"¥", "plusmn":"±", "minus":"−", "sup1":"¹", "sup2":"²", "sup3":"³",
        "aacute":"á", "eacute":"é", "iacute":"í", "oacute":"ó", "uacute":"ú", "agrave":"à", "egrave":"è", "igrave":"ì", "ograve":"ò", "ugrave":"ù",
        "acirc":"â", "ecirc":"ê", "icirc":"î", "ocirc":"ô", "ucirc":"û", "auml":"ä", "euml":"ë", "iuml":"ï", "ouml":"ö", "uuml":"ü",
        "Aacute":"Á", "Eacute":"É", "Iacute":"Í", "Oacute":"Ó", "Uacute":"Ú", "Auml":"Ä", "Ouml":"Ö", "Uuml":"Ü",
        "atilde":"ã", "otilde":"õ", "ntilde":"ñ", "ccedil":"ç", "aelig":"æ", "AElig":"Æ", "oelig":"œ", "OElig":"Œ", "oslash":"ø", "szlig":"ß",
        "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ε", "zeta":"ζ", "eta":"η", "theta":"θ", "iota":"ι", "kappa":"κ", "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "omicron":"ο", "pi":"π", "rho":"ρ", "sigma":"σ", "tau":"τ", "upsilon":"υ", "phi":"φ", "chi":"χ", "psi":"ψ", "omega":"ω",
        "larr":"←", "rarr":"→", "harr":"↔", "ne":"≠", "le":"≤", "ge":"≥", "frac12":"½", "frac14":"¼", "frac34":"¾"
    ]
}
