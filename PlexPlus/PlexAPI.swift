import Foundation

enum PlexError: LocalizedError {
    case http(Int)
    case badResponse
    case noReachableConnection
    case notLinked

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Plex returned HTTP \(code)."
        case .badResponse: return "Unexpected response from Plex."
        case .noReachableConnection: return "Couldn't reach the Plex server."
        case .notLinked: return "Not signed in to Plex."
        }
    }
}

/// A thin async client for the Plex.tv account API and Plex Media Server.
/// Stateless apart from a stable client identifier; auth/server tokens are
/// passed in per call by the view model.
final class PlexAPI {
    let clientID: String
    let product = "PlexPlus"
    let version = "1.0"

    #if os(macOS)
    let platform = "macOS"
    let device = "PlexPlus (Mac)"
    #else
    let platform = "iOS"
    let device = "PlexPlus (iPad)"
    #endif

    /// Platform name used for transcode requests. PMS resolves the client
    /// profile from X-Plex-Platform and ships no "macOS" profile, so such
    /// requests fail with "unable to find client profile" (HTTP 400). The
    /// iOS profile is HLS-native and matches AVFoundation on both platforms.
    let transcodeProfilePlatform = "iOS"

    init() {
        if let existing = KeychainHelper.get("plex.clientId") {
            clientID = existing
        } else {
            let generated = UUID().uuidString
            KeychainHelper.set(generated, for: "plex.clientId")
            clientID = generated
        }
    }

    // MARK: Requests

    private func headers(token: String?) -> [String: String] {
        var h = [
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Platform": platform,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": device,
            "Accept": "application/json",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    private func request(_ url: URL, method: String = "GET", token: String?,
                         body: Data? = nil, contentType: String? = nil,
                         timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                NetworkLog.record(method: method, url: url, start: start,
                                  bytes: data.count, error: "No HTTP response")
                throw PlexError.badResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                NetworkLog.record(method: method, url: url, start: start, status: http.statusCode,
                                  bytes: data.count, error: "HTTP \(http.statusCode)",
                                  detail: String(data: data.prefix(300), encoding: .utf8))
                throw PlexError.http(http.statusCode)
            }
            NetworkLog.record(method: method, url: url, start: start,
                              status: http.statusCode, bytes: data.count)
            return data
        } catch let error where !(error is PlexError) {
            NetworkLog.record(method: method, url: url, start: start,
                              error: (error as NSError).localizedDescription)
            throw error
        }
    }

    private func get<T: Decodable>(_ url: URL, token: String?, timeout: TimeInterval = 15) async throws -> T {
        let data = try await request(url, token: token, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Authentication (PIN linking)

    /// Requests a short (4-character) PIN. We deliberately avoid `strong=true`:
    /// strong PINs are long and only work through the deep-link auth URL, not
    /// manual entry at plex.tv/link.
    func createPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins")!
        let data = try await request(url, method: "POST", token: nil,
                                     body: "strong=false".data(using: .utf8),
                                     contentType: "application/x-www-form-urlencoded")
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    func checkPin(id: Int) async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        return try await get(url, token: nil)
    }

    /// The page the user visits to authorize this app by entering the PIN.
    /// (The `app.plex.tv/auth` deep link now redirects to the Plex web app, so
    /// we use the plain link page and rely on the 4-character code.)
    let linkPageURL = URL(string: "https://plex.tv/link")!

    // MARK: Server discovery

    func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await get(url, token: token)
    }

    /// Probe every connection concurrently and return the best-ranked one that
    /// answers (local preferred, then remote, then relay). Probing in parallel
    /// avoids waiting out a timeout on a dead address before trying the next.
    func reachableBaseURL(for server: PlexResource) async -> (base: URL, token: String)? {
        guard let token = server.accessToken, let connections = server.connections else { return nil }
        let ordered = connections.sorted { rank($0) < rank($1) }
        let best: (rank: Int, base: URL)? = await withTaskGroup(of: (Int, URL)?.self) { group in
            for (index, connection) in ordered.enumerated() {
                guard let base = URL(string: connection.uri) else { continue }
                group.addTask { [self] in await probe(base: base, token: token) ? (index, base) : nil }
            }
            var chosen: (Int, URL)?
            for await result in group {
                if let result, chosen == nil || result.0 < chosen!.0 { chosen = result }
            }
            return chosen
        }
        if let best { return (best.base, token) }
        return nil
    }

    private func rank(_ c: PlexConnection) -> Int {
        if c.relay == true { return 2 }
        return c.local ? 0 : 1
    }

    /// Quick reachability check against a base URL.
    func probe(base: URL, token: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: base.absoluteString + "/identity") else { return false }
        do {
            _ = try await request(url, token: token, timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    // MARK: Library

    func sections(base: URL, token: String) async throws -> [PlexDirectory] {
        let url = URL(string: base.absoluteString + "/library/sections")!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.directory ?? []
    }

    func onDeck(base: URL, token: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/onDeck", base: base, token: token)
    }

    func recentlyAdded(base: URL, token: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/recentlyAdded", base: base, token: token)
    }

    /// Plex matches the `title` filter against the *sort* title, which strips
    /// leading articles ("The West Wing" indexes as "West Wing") - so a query
    /// typed with the article can return nothing. Run the query as typed plus
    /// an article-stripped variant and merge, deduplicated by ratingKey.
    func searchLibrarySmart(base: URL, token: String, sectionKey: String,
                            type: Int?, query: String, sort: String? = nil) async throws -> [PlexMetadata] {
        var variants = [query]
        let lowered = query.lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) && query.count > article.count {
            variants.append(String(query.dropFirst(article.count)))
        }
        var seen = Set<String>()
        var merged: [PlexMetadata] = []
        for variant in variants {
            let items = (try? await searchLibrary(base: base, token: token, sectionKey: sectionKey,
                                                  type: type, query: variant, sort: sort)) ?? []
            for item in items where seen.insert(item.ratingKey).inserted {
                merged.append(item)
            }
        }
        return merged
    }

    /// A page of items in a section, filtered by `type` (1 = movie, 2 = show,
    /// 4 = episode) and sorted (e.g. "addedAt:desc"). Paginated via
    /// `X-Plex-Container-Start/Size` so enormous libraries load a page at a time
    /// instead of timing out on one gigantic response.
    func sectionItems(base: URL, token: String, sectionKey: String,
                      type: Int?, sort: String?,
                      start: Int = 0, size: Int? = nil,
                      onResponse: @escaping (Int) -> Void = { _ in },
                      onProgress: @escaping (Int) -> Void = { _ in }) async throws -> [PlexMetadata] {
        var params: [String] = ["X-Plex-Container-Start=\(start)"]
        if let size { params.append("X-Plex-Container-Size=\(size)") }
        if let type { params.append("type=\(type)") }
        if let sort, !sort.isEmpty { params.append("sort=\(sort)") }
        let path = "/library/sections/\(sectionKey)/all?" + params.joined(separator: "&")
        return try await fetchMetadataList(path: path, base: base, token: token,
                                           onResponse: onResponse, onProgress: onProgress)
    }

    func children(base: URL, token: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/metadata/\(ratingKey)/children", base: base, token: token)
    }

    /// Server-side "title contains" search within a section (works on huge
    /// libraries since the server does the matching). Plex's free-text search
    /// has no boolean operators, so this is a substring title match.
    func searchLibrary(base: URL, token: String, sectionKey: String,
                       type: Int?, query: String, sort: String? = nil,
                       onResponse: @escaping (Int) -> Void = { _ in },
                       onProgress: @escaping (Int) -> Void = { _ in }) async throws -> [PlexMetadata] {
        // .alphanumerics so "&" and "=" in the query are escaped (urlQueryAllowed leaves them raw).
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        var params = ["title=" + enc(query), "X-Plex-Container-Start=0", "X-Plex-Container-Size=200"]
        if let type { params.append("type=\(type)") }
        if let sort, !sort.isEmpty { params.append("sort=" + sort) }
        let path = "/library/sections/\(sectionKey)/all?" + params.joined(separator: "&")
        return try await fetchMetadataList(path: path, base: base, token: token,
                                           onResponse: onResponse, onProgress: onProgress)
    }

    func hubs(base: URL, token: String, sectionKey: String,
              onResponse: @escaping (Int) -> Void = { _ in },
              onProgress: @escaping (Int) -> Void = { _ in }) async throws -> [PlexHub] {
        let data = try await fetchData(path: "/hubs/sections/\(sectionKey)?count=20",
                                       base: base, token: token,
                                       onResponse: onResponse, onProgress: onProgress)
        return (try JSONDecoder().decode(MediaContainerResponse.self, from: data)).mediaContainer.hub ?? []
    }

    func playlists(base: URL, token: String) async throws -> [PlexMetadata] {
        let url = URL(string: base.absoluteString + "/playlists")!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.metadata ?? []
    }

    func playlistItems(base: URL, token: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await fetchMetadataList(path: "/playlists/\(ratingKey)/items", base: base, token: token)
    }

    func fetchMetadataList(path: String, base: URL, token: String,
                           timeout: TimeInterval = 120,
                           onResponse: @escaping (Int) -> Void = { _ in },
                           onProgress: @escaping (Int) -> Void = { _ in }) async throws -> [PlexMetadata] {
        let data = try await fetchData(path: path, base: base, token: token, timeout: timeout,
                                       onResponse: onResponse, onProgress: onProgress)
        return try JSONDecoder().decode(MediaContainerResponse.self, from: data).mediaContainer.metadata ?? []
    }

    /// Core fetch with a generous timeout that reports the HTTP status the
    /// moment headers arrive and the running byte count as the body downloads.
    func fetchData(path: String, base: URL, token: String,
                   timeout: TimeInterval = 120,
                   onResponse: @escaping (Int) -> Void = { _ in },
                   onProgress: @escaping (Int) -> Void = { _ in }) async throws -> Data {
        let url = URL(string: base.absoluteString + path)!
        var req = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        let observer = PlexProgressObserver(onResponse: onResponse, onProgress: onProgress)
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req, delegate: observer)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (resp as? HTTPURLResponse)?.statusCode
                NetworkLog.record(url: url, start: start, status: status,
                                  bytes: data.count, error: "HTTP \(status ?? -1)",
                                  detail: String(data: data.prefix(300), encoding: .utf8))
                throw PlexError.http(status ?? -1)
            }
            NetworkLog.record(url: url, start: start, status: http.statusCode, bytes: data.count)
            return data
        } catch let error where !(error is PlexError) {
            NetworkLog.record(url: url, start: start,
                              error: (error as NSError).localizedDescription)
            throw error
        }
    }

    /// Full metadata for one item (includes Media/Part technical fields + file path).
    func metadata(base: URL, token: String, ratingKey: String) async throws -> PlexMetadata? {
        try await metadataList(path: "/library/metadata/\(ratingKey)", base: base, token: token).first
    }

    /// Deletes a media item (and its file, if the server allows deletion).
    func deleteItem(base: URL, token: String, ratingKey: String) async throws {
        let url = URL(string: base.absoluteString + "/library/metadata/\(ratingKey)")!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "DELETE"
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private func metadataList(path: String, base: URL, token: String) async throws -> [PlexMetadata] {
        let url = URL(string: base.absoluteString + path)!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.metadata ?? []
    }

    // MARK: Media URLs

    func imageURL(base: URL, token: String, path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: base.absoluteString + path + "?X-Plex-Token=" + token)
    }

    /// Whether the given item at the given quality will be transcoded (vs
    /// direct-played). The caller uses this to know if it must later stop the
    /// transcode session.
    func willTranscode(item: PlexMetadata, quality: PlexQuality) -> Bool {
        !(quality == .original && item.partKey != nil && canDirectPlay(item))
    }

    /// A URL AVPlayer can play at the requested quality. `.original` direct-plays
    /// only files AVFoundation can natively handle (mp4/mov/m4v with H.264/HEVC
    /// video and AAC/MP3 audio); anything else — e.g. AVI or MKV — is sent to
    /// the Plex universal transcoder (HLS). `session` identifies the transcode
    /// so it can be stopped later.
    func playbackURL(base: URL, token: String, item: PlexMetadata,
                     quality: PlexQuality, session: String) -> URL? {
        if quality == .original, let partKey = item.partKey, canDirectPlay(item) {
            return URL(string: base.absoluteString + partKey + "?X-Plex-Token=" + token)
        }
        return transcodeURL(base: base, token: token, item: item, quality: quality, session: session)
    }

    /// Whether AVFoundation can most likely play the file as-is. The container
    /// is the deciding factor: AVPlayer opens mp4/mov/m4v and natively handles
    /// the codecs commonly inside them (H.264/HEVC video; AAC/MP3/ALAC and
    /// AC-3/E-AC-3 audio). Plex codec metadata is often missing or wrong, and
    /// being strict here forces an unnecessary transcode - which some hosts
    /// block outright - so err on the side of direct play; a real playback
    /// failure automatically falls back to the transcoder.
    func canDirectPlay(_ item: PlexMetadata) -> Bool {
        guard let container = item.partContainer?.lowercased() else { return false }
        return ["mp4", "mov", "m4v"].contains(container)
    }

    func transcodeURL(base: URL, token: String, item: PlexMetadata,
                      quality: PlexQuality, session: String) -> URL? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        // A per-playback session id is required by the universal transcoder.
        // The parameter set mirrors what official Plex clients send - servers
        // (and proxies in front of them) can reject sparser requests with 400.
        var params = [
            "hasMDE=1",
            "path=" + enc("/library/metadata/\(item.ratingKey)"),
            "mediaIndex=0",
            "partIndex=0",
            "protocol=hls",
            "fastSeek=1",
            "directPlay=0",
            "directStream=1",
            "directStreamAudio=1",
            "subtitles=auto",
            "audioBoost=100",
            "subtitleSize=100",
            "location=wan",
            "autoAdjustQuality=0",
            "mediaBufferSize=102400",
            "videoQuality=100",
            "session=" + enc(session),
            "X-Plex-Session-Identifier=" + enc(session),
            "X-Plex-Client-Identifier=" + enc(clientID),
            "X-Plex-Product=" + enc(product),
            "X-Plex-Version=" + enc(version),
            "X-Plex-Platform=" + enc(transcodeProfilePlatform),
            "X-Plex-Device=" + enc(device),
            "X-Plex-Device-Name=" + enc(device),
            "X-Plex-Token=" + enc(token),
        ]
        if let bitrate = quality.maxVideoBitrateKbps {
            params.append("maxVideoBitrate=\(bitrate)")
        }
        if let resolution = quality.videoResolution {
            params.append("videoResolution=" + resolution)
        }
        return URL(string: base.absoluteString + "/video/:/transcode/universal/start.m3u8?"
                   + params.joined(separator: "&"))
    }

    /// Fires a series of transcode requests with different parameter shapes
    /// and encodings, logging each result - a one-button experiment to find
    /// which shape (if any) this server accepts. Results appear in the
    /// Network Log labeled "probe ...".
    func runTranscodeProbe(base: URL, token: String, item: PlexMetadata,
                           altBases: [URL] = []) async {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        func encU(_ s: String) -> String { // RFC 3986 unreserved: -._~ stay literal
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let session = UUID().uuidString
        let path = "/library/metadata/\(item.ratingKey)"

        var variants: [(String, String)] = []
        variants.append(("probe v0 (bare endpoint, token only)",
            "X-Plex-Token=" + encU(token)))
        variants.append(("probe v1 (original app params)", [
            "path=" + enc(path), "mediaIndex=0", "partIndex=0", "protocol=hls",
            "fastSeek=1", "directPlay=0", "directStream=1", "subtitles=burn",
            "videoQuality=100", "maxVideoBitrate=20000",
            "X-Plex-Client-Identifier=" + enc(clientID),
            "X-Plex-Product=" + enc(product),
            "X-Plex-Platform=" + enc(platform),
            "X-Plex-Token=" + enc(token),
        ].joined(separator: "&")))
        let v2Query = [
            "path=" + encU(path), "mediaIndex=0", "partIndex=0", "protocol=hls",
            "fastSeek=1", "directPlay=0", "directStream=1", "subtitles=burn",
            "videoQuality=100", "maxVideoBitrate=20000",
            "session=" + encU(session),
            "X-Plex-Client-Identifier=" + encU(clientID),
            "X-Plex-Product=" + encU(product),
            "X-Plex-Platform=" + encU(platform),
            "X-Plex-Token=" + encU(token),
        ].joined(separator: "&")
        variants.append(("probe v2 (v1 + unreserved encoding)", v2Query))
        variants.append(("probe v3 (minimal)", [
            "path=" + encU(path), "protocol=hls",
            "X-Plex-Client-Identifier=" + encU(clientID),
            "X-Plex-Token=" + encU(token),
        ].joined(separator: "&")))

        for (label, query) in variants {
            guard let url = URL(string: base.absoluteString
                                + "/video/:/transcode/universal/start.m3u8?" + query) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 30)
            for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
            let start = Date()
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                NetworkLog.record(url: url, start: start,
                                  status: (resp as? HTTPURLResponse)?.statusCode, bytes: data.count,
                                  detail: String(data: data.prefix(200), encoding: .utf8),
                                  label: label)
            } catch {
                NetworkLog.record(url: url, start: start,
                                  error: (error as NSError).localizedDescription, label: label)
            }
        }
        // The same canonical request via every other advertised connection -
        // a broken proxy on one address doesn't affect the others.
        await withTaskGroup(of: Void.self) { group in
            for alt in altBases where alt.absoluteString != base.absoluteString {
                group.addTask { [self] in
                    guard let url = URL(string: alt.absoluteString
                                        + "/video/:/transcode/universal/start.m3u8?" + v2Query) else { return }
                    var req = URLRequest(url: url, timeoutInterval: 10)
                    for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
                    let start = Date()
                    do {
                        let (data, resp) = try await URLSession.shared.data(for: req)
                        NetworkLog.record(url: url, start: start,
                                          status: (resp as? HTTPURLResponse)?.statusCode, bytes: data.count,
                                          detail: String(data: data.prefix(200), encoding: .utf8),
                                          label: "probe via \(alt.host ?? "alt"):\(alt.port ?? 32400)")
                    } catch {
                        NetworkLog.record(url: url, start: start,
                                          error: (error as NSError).localizedDescription,
                                          label: "probe via \(alt.host ?? "alt"):\(alt.port ?? 32400)")
                    }
                }
            }
        }
        // Best-effort cleanup of any session the probes started.
        await stopTranscode(base: base, token: token, session: session)
    }

    // MARK: Playlists (write)

    /// Creates a regular (non-smart) playlist on the server from the given items.
    func createPlaylist(base: URL, token: String, machineID: String,
                        title: String, type: String = "video",
                        ratingKeys: [String]) async throws {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let uri = "server://\(machineID)/com.plexapp.plugins.library/library/metadata/"
            + ratingKeys.joined(separator: ",")
        let url = URL(string: base.absoluteString + "/playlists?type=\(type)&smart=0"
                      + "&title=" + enc(title) + "&uri=" + enc(uri))!
        _ = try await request(url, method: "POST", token: token)
    }

    /// Asks the server to explain its transcode decision for the same request
    /// the player is about to make. Purely diagnostic: the structured verdict
    /// (or refusal) lands in the network log.
    func logTranscodeDecision(base: URL, token: String, item: PlexMetadata,
                              quality: PlexQuality, session: String) async {
        guard let startURL = transcodeURL(base: base, token: token, item: item,
                                          quality: quality, session: session),
              var comps = URLComponents(string: base.absoluteString + "/video/:/transcode/universal/decision")
        else { return }
        comps.percentEncodedQuery = URLComponents(url: startURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            NetworkLog.record(url: url, start: start,
                              status: (resp as? HTTPURLResponse)?.statusCode, bytes: data.count,
                              detail: String(data: data.prefix(300), encoding: .utf8),
                              label: "Transcode decision")
        } catch {
            NetworkLog.record(url: url, start: start,
                              error: (error as NSError).localizedDescription,
                              label: "Transcode decision")
        }
    }

    /// Tells the server to stop a universal-transcode session so it doesn't keep
    /// transcoding until its own timeout.
    func stopTranscode(base: URL, token: String, session: String) async {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let path = "/video/:/transcode/universal/stop?session=\(enc(session))"
            + "&X-Plex-Client-Identifier=\(enc(clientID))&X-Plex-Token=\(enc(token))"
        guard let url = URL(string: base.absoluteString + path) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Reports playback progress so the server updates On Deck / resume points /
    /// watched state. `state` is playing / paused / stopped.
    func reportTimeline(base: URL, token: String, ratingKey: String, key: String,
                        state: String, timeMs: Int, durationMs: Int) async {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let params = [
            "ratingKey=\(enc(ratingKey))",
            "key=\(enc(key))",
            "state=\(state)",
            "time=\(max(0, timeMs))",
            "duration=\(max(0, durationMs))",
            "hasMDE=1",
            "X-Plex-Client-Identifier=\(enc(clientID))",
            "X-Plex-Token=\(enc(token))",
        ]
        guard let url = URL(string: base.absoluteString + "/:/timeline?" + params.joined(separator: "&")) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// Selectable playback quality for the Plex player.
enum PlexQuality: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p (20 Mbps)"
    case p720 = "720p (4 Mbps)"
    case p480 = "480p (2 Mbps)"

    var id: String { rawValue }

    var maxVideoBitrateKbps: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 20000
        case .p720: return 4000
        case .p480: return 2000
        }
    }

    var videoResolution: String? {
        switch self {
        case .original: return nil
        case .p1080: return "1920x1080"
        case .p720: return "1280x720"
        case .p480: return "720x480"
        }
    }
}

/// Sortable fields for the Browse tab.
enum PlexSortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case releaseDate = "Release Date"
    case dateAdded = "Date Added"
    case duration = "Duration"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .name: return "titleSort"
        case .releaseDate: return "originallyAvailableAt"
        case .dateAdded: return "addedAt"
        case .duration: return "duration"
        }
    }
}

/// Per-task delegate that reports the HTTP status when headers arrive and the
/// running byte count as the body streams — used for the network debug overlay
/// and to tell "no response yet" apart from "downloading".
final class PlexProgressObserver: NSObject, URLSessionDataDelegate {
    private let onResponse: (Int) -> Void
    private let onProgress: (Int) -> Void
    private var responded = false
    private var bytes = 0

    init(onResponse: @escaping (Int) -> Void = { _ in },
         onProgress: @escaping (Int) -> Void = { _ in }) {
        self.onResponse = onResponse
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if !responded {
            responded = true
            onResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += data.count
        onProgress(bytes)
    }
}
