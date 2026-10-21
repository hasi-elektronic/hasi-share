import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A `<channel>` of an XMLTV document.
public struct XMLTVChannel: Codable, Sendable, Hashable {
    public var id: String
    /// All `display-name` values in document order.
    public var displayNames: [String]
    /// First `icon@src`.
    public var icon: String?

    public init(id: String, displayNames: [String], icon: String?) {
        self.id = id
        self.displayNames = displayNames
        self.icon = icon
    }
}

/// A `<programme>` after time parsing, language selection, shift and stop filling.
public struct XMLTVProgramme: Codable, Sendable, Hashable {
    /// Raw `programme@channel`.
    public var channel: String
    public var start: Date
    public var end: Date
    public var title: String
    public var description: String?
    public var category: String?

    public init(channel: String, start: Date, end: Date, title: String, description: String?, category: String?) {
        self.channel = channel
        self.start = start
        self.end = end
        self.title = title
        self.description = description
        self.category = category
    }

    /// Domain programme for `sourceId`. `channelEpgId` is the matched channel's epg id when
    /// known (see `EpgMatcher`), else the raw XMLTV channel id.
    public func toEpgProgram(sourceId: String, channelEpgId: String? = nil) -> EpgProgram {
        EpgProgram(sourceId: sourceId, channelEpgId: channelEpgId ?? channel, start: start, end: end,
                   title: title, description: description, category: category)
    }
}

/// Parsing options.
public struct XMLTVParseOptions: Sendable, Hashable {
    /// UI language ("tr", "en", "tr-TR"…): `title`/`desc` with a matching `lang` win, else the first.
    public var preferredLanguage: String?
    /// The source's `epgShiftMinutes`, added to start and stop.
    public var shiftMinutes: Int
    /// Retention window (see `EpgRetention.window`); programmes not overlapping it are dropped.
    public var window: DateInterval?
    /// Maximum programmes per `onProgrammes` call.
    public var batchSize: Int

    public init(preferredLanguage: String? = nil, shiftMinutes: Int = 0, window: DateInterval? = nil, batchSize: Int = 1000) {
        self.preferredLanguage = preferredLanguage
        self.shiftMinutes = shiftMinutes
        self.window = window
        self.batchSize = batchSize
    }
}

/// Counters of a finished XMLTV parse.
public struct XMLTVSummary: Sendable, Hashable {
    public var channelCount = 0
    public var programmeCount = 0
    /// Invalid start, missing channel, or end ≤ start.
    public var invalidCount = 0
    /// Outside the retention window.
    public var outsideWindowCount = 0
    /// The XML was cut off or malformed after valid content (partial result kept).
    public var truncated = false

    public init() {}
}

/// Fully materialized parse result (tests, small files). Programmes sorted by (channel, start).
public struct XMLTVDocument: Sendable, Hashable {
    public var channels: [XMLTVChannel]
    public var programmes: [XMLTVProgramme]
    public var summary: XMLTVSummary
}

/// Streaming XMLTV parser (CONTRACT §5) built on Foundation's SAX `XMLParser` reading from an
/// `InputStream`, so huge guides are never loaded into memory.
///
/// Stop-time filling: a programme without a valid `stop` gets the start of the next programme
/// (in document order) on the same channel that starts later, else start + 30 min. Only such
/// programmes are held back; everything else is emitted as soon as it is parsed.
public enum XMLTVParser {
    /// Parses XML from a stream (must not be gzip – use `parse(fileURL:)`/`parse(data:)` for that).
    /// Throws `SourceError.invalidFormat` if the document is not XMLTV, `.cancelled` on task
    /// cancellation, or rethrows an error thrown by a callback.
    @discardableResult
    public static func parse(stream: InputStream, options: XMLTVParseOptions = XMLTVParseOptions(),
                             onChannel: @escaping (XMLTVChannel) -> Void,
                             onProgrammes: @escaping ([XMLTVProgramme]) throws -> Void) throws -> XMLTVSummary {
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = XMLTVParserDelegate(options: options, onChannel: onChannel, onProgrammes: onProgrammes)
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.callbackError { throw error }
        if delegate.cancelled { throw SourceError.cancelled }
        if delegate.rootState != .tv { throw SourceError.invalidFormat }
        if !ok {
            if delegate.summary.channelCount == 0 && delegate.programmesSeen == 0 { throw SourceError.invalidFormat }
            delegate.summary.truncated = true
        }
        delegate.finish()
        if let error = delegate.callbackError { throw error }
        return delegate.summary
    }

    /// Parses a file (plain or gzip, detected by magic bytes). gzip is inflated in chunks into
    /// a temporary file next to the system temp directory, which is removed afterwards.
    @discardableResult
    public static func parse(fileURL: URL, options: XMLTVParseOptions = XMLTVParseOptions(),
                             onChannel: @escaping (XMLTVChannel) -> Void,
                             onProgrammes: @escaping ([XMLTVProgramme]) throws -> Void) throws -> XMLTVSummary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw SourceError.notFound }
        if try fileIsGzip(fileURL) {
            let plain = FileManager.default.temporaryDirectory
                .appendingPathComponent("xmltv-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: plain) }
            do {
                try Gzip.decompressFile(at: fileURL, to: plain)
            } catch let error as SourceError {
                throw error
            } catch {
                throw SourceError.invalidFormat
            }
            return try parsePlainFile(plain, options: options, onChannel: onChannel, onProgrammes: onProgrammes)
        }
        return try parsePlainFile(fileURL, options: options, onChannel: onChannel, onProgrammes: onProgrammes)
    }

    /// Parses an in-memory document (plain or gzip) and returns everything, programmes sorted
    /// by (channel, start).
    public static func parse(data: Data, options: XMLTVParseOptions = XMLTVParseOptions()) throws -> XMLTVDocument {
        let xml: Data
        if Gzip.isGzip(data) {
            do { xml = try Gzip.decompress(data) } catch { throw SourceError.invalidFormat }
        } else {
            xml = data
        }
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
        let summary = try parse(stream: InputStream(data: xml), options: options,
                                onChannel: { channels.append($0) },
                                onProgrammes: { programmes.append(contentsOf: $0) })
        programmes.sort { ($0.channel, $0.start) < ($1.channel, $1.start) }
        return XMLTVDocument(channels: channels, programmes: programmes, summary: summary)
    }

    private static func parsePlainFile(_ url: URL, options: XMLTVParseOptions,
                                       onChannel: @escaping (XMLTVChannel) -> Void,
                                       onProgrammes: @escaping ([XMLTVProgramme]) throws -> Void) throws -> XMLTVSummary {
        guard let stream = InputStream(url: url) else { throw SourceError.notFound }
        return try parse(stream: stream, options: options, onChannel: onChannel, onProgrammes: onProgrammes)
    }

    static func fileIsGzip(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Gzip.isGzip(handle.readData(ofLength: 2))
    }
}

// MARK: - Delegate

final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    enum RootState { case unknown, tv, other }
    private enum Capture { case displayName, title(String?), desc(String?), category }

    private struct Pending {
        var channel: String
        var start: Date
        var title: String
        var description: String?
        var category: String?
    }

    private let options: XMLTVParseOptions
    private let onChannel: (XMLTVChannel) -> Void
    private let onProgrammes: ([XMLTVProgramme]) throws -> Void
    private let preferredPrimary: String?
    private let shift: TimeInterval

    var summary = XMLTVSummary()
    var rootState = RootState.unknown
    var callbackError: Error?
    var cancelled = false
    var programmesSeen = 0

    private var depth = 0
    private var capture: Capture?
    private var text = ""

    private var channelId: String?
    private var channelNames: [String] = []
    private var channelIcon: String?

    private var inProgramme = false
    private var progChannel = ""
    private var progStart: Date?
    private var progStop: Date?
    private var titles: [(String?, String)] = []
    private var descs: [(String?, String)] = []
    private var category: String?

    private var pending: [String: [Pending]] = [:]
    private var batch: [XMLTVProgramme] = []

    init(options: XMLTVParseOptions, onChannel: @escaping (XMLTVChannel) -> Void,
         onProgrammes: @escaping ([XMLTVProgramme]) throws -> Void) {
        self.options = options
        self.onChannel = onChannel
        self.onProgrammes = onProgrammes
        self.preferredPrimary = options.preferredLanguage.map(XMLTVParserDelegate.primaryLanguage)
        self.shift = TimeInterval(options.shiftMinutes * 60)
        batch.reserveCapacity(options.batchSize)
    }

    static func primaryLanguage(_ tag: String) -> String {
        String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if rootState == .unknown {
            rootState = elementName == "tv" ? .tv : .other
            if rootState == .other { parser.abortParsing() }
            return
        }
        switch elementName {
        case "channel" where depth == 2:
            channelId = attributeDict["id"]
            channelNames = []
            channelIcon = nil
        case "display-name" where channelId != nil:
            beginCapture(.displayName)
        case "icon" where channelId != nil && !inProgramme:
            if channelIcon == nil, let src = attributeDict["src"], !src.isEmpty { channelIcon = src }
        case "programme" where depth == 2:
            programmesSeen += 1
            if programmesSeen % 2000 == 0, Task.isCancelled {
                cancelled = true
                parser.abortParsing()
                return
            }
            inProgramme = true
            progChannel = attributeDict["channel"] ?? ""
            progStart = attributeDict["start"].flatMap(XMLTVTime.parse)?.addingTimeInterval(shift)
            progStop = attributeDict["stop"].flatMap(XMLTVTime.parse)?.addingTimeInterval(shift)
            titles = []
            descs = []
            category = nil
        case "title" where inProgramme:
            beginCapture(.title(attributeDict["lang"]))
        case "desc" where inProgramme:
            beginCapture(.desc(attributeDict["lang"]))
        case "category" where inProgramme && category == nil:
            beginCapture(.category)
        default:
            break
        }
    }

    private func beginCapture(_ c: Capture) {
        capture = c
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capture != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { depth -= 1 }
        if let c = capture {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (c, elementName) {
            case (.displayName, "display-name"):
                if !value.isEmpty { channelNames.append(value) }
                capture = nil
            case (.title(let lang), "title"):
                if !value.isEmpty { titles.append((lang, value)) }
                capture = nil
            case (.desc(let lang), "desc"):
                if !value.isEmpty { descs.append((lang, value)) }
                capture = nil
            case (.category, "category"):
                if !value.isEmpty { category = value }
                capture = nil
            default:
                break
            }
        }
        if elementName == "channel" && depth == 2, let id = channelId {
            if !id.isEmpty {
                summary.channelCount += 1
                onChannel(XMLTVChannel(id: id, displayNames: channelNames, icon: channelIcon))
            }
            channelId = nil
        } else if elementName == "programme" && depth == 2 && inProgramme {
            inProgramme = false
            finishProgramme()
            if callbackError != nil { parser.abortParsing() }
        }
    }

    private func pick(_ candidates: [(String?, String)]) -> String? {
        if let preferred = preferredPrimary,
           let match = candidates.first(where: { $0.0.map(XMLTVParserDelegate.primaryLanguage) == preferred }) {
            return match.1
        }
        return candidates.first?.1
    }

    private func finishProgramme() {
        guard !progChannel.isEmpty, let start = progStart else {
            summary.invalidCount += 1
            return
        }
        // Resolve held-back programmes of this channel that start earlier.
        if var waiting = pending[progChannel] {
            var remaining: [Pending] = []
            for item in waiting {
                if start > item.start {
                    emit(channel: item.channel, start: item.start, end: start, title: item.title,
                         description: item.description, category: item.category)
                } else {
                    remaining.append(item)
                }
            }
            waiting = remaining
            pending[progChannel] = waiting.isEmpty ? nil : waiting
        }
        let title = pick(titles) ?? ""
        let description = pick(descs)
        if let stop = progStop {
            emit(channel: progChannel, start: start, end: stop, title: title, description: description, category: category)
        } else {
            pending[progChannel, default: []].append(Pending(channel: progChannel, start: start, title: title,
                                                             description: description, category: category))
        }
    }

    private func emit(channel: String, start: Date, end: Date, title: String, description: String?, category: String?) {
        guard end > start else {
            summary.invalidCount += 1
            return
        }
        if let window = options.window, !(end > window.start && start < window.end) {
            summary.outsideWindowCount += 1
            return
        }
        summary.programmeCount += 1
        batch.append(XMLTVProgramme(channel: channel, start: start, end: end, title: title,
                                    description: description, category: category))
        if batch.count >= options.batchSize { flush() }
    }

    private func flush() {
        guard !batch.isEmpty, callbackError == nil else { return }
        do {
            try onProgrammes(batch)
        } catch {
            callbackError = error
        }
        batch.removeAll(keepingCapacity: true)
    }

    /// End of input: remaining held-back programmes get start + 30 min, then the last batch.
    func finish() {
        for channel in pending.keys.sorted() {
            for item in pending[channel] ?? [] {
                emit(channel: item.channel, start: item.start, end: item.start.addingTimeInterval(30 * 60),
                     title: item.title, description: item.description, category: item.category)
            }
        }
        pending.removeAll()
        flush()
    }
}
