import SwiftUI
import AVKit
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An audio or subtitle track option. `id == -1` means "Off" (subtitles).
struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let name: String
}

/// Live network diagnostics for a single request, shown in the debug overlay.
struct NetStat: Equatable {
    var label: String = ""
    var path: String = ""
    var phase: String = "idle"          // idle / connecting / downloading / done / failed
    var httpStatus: Int?
    var bytes: Int = 0
    var responseSeconds: Double?
    var finishedSeconds: Double?
    var error: String?

    var statusLine: String {
        var s = phase
        if let httpStatus { s += " · HTTP \(httpStatus)" }
        if let responseSeconds { s += String(format: " · resp %.2fs", responseSeconds) }
        if let finishedSeconds { s += String(format: " · done %.2fs", finishedSeconds) }
        return s
    }

    var detailLine: String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)]
        if let error { parts.append("⚠︎ " + error) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - View model

@MainActor
final class PlexPlayerViewModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case linking(code: String)
        case loading(String)
        case browsing
        case error(String)
    }

    enum BrowseMode: Equatable {
        case home
        case library(PlexLibraryRef)
    }

    enum LibraryTab: String, CaseIterable, Identifiable {
        case recommended = "Recommended"
        case browse = "Browse"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    /// Load state for the (potentially large) Browse list. Distinguishes
    /// "waiting to connect" from "server is responding, downloading".
    enum LoadState: Equatable {
        case idle
        case connecting
        case downloading
        case ready
        case failed(String)
    }

    struct BrowseLevel: Identifiable {
        let id = UUID()
        let title: String
        var items: [PlexMetadata]
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var servers: [PlexResource] = []
    @Published private(set) var selectedServer: PlexResource?
    @Published private(set) var onDeck: [PlexMetadata] = []
    @Published private(set) var recentlyAdded: [PlexMetadata] = []
    @Published private(set) var sections: [PlexDirectory] = []
    @Published private(set) var serverLibraries: [String: [PlexDirectory]] = [:]

    // Library browsing
    @Published private(set) var mode: BrowseMode = .home
    @Published private(set) var stack: [BrowseLevel] = []
    @Published var libraryTab: LibraryTab = .browse
    @Published var sortField: PlexSortField = .name
    @Published var sortAscending = true
    @Published var tvEpisodes = false
    @Published private(set) var recommendedHubs: [PlexHub] = []
    @Published private(set) var browseItems: [PlexMetadata] = []
    @Published private(set) var playlists: [PlexMetadata] = []
    @Published private(set) var libraryLoadState: LoadState = .idle
    @Published private(set) var tabLoading = false
    @Published private(set) var browseHasMore = false
    @Published private(set) var browseLoadingMore = false

    // Network debug overlay (toggle lives in Settings / PlexPreferences)
    @Published private(set) var browseNet = NetStat()
    @Published private(set) var recommendedNet = NetStat()

    private let browsePageSize = 300
    private var browseKey = ""

    // Search (within the current library)
    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published private(set) var searchResults: [PlexMetadata] = []
    @Published private(set) var searchActive = false
    @Published private(set) var searching = false
    private var searchTask: Task<Void, Never>?

    // Player
    @Published var player: AVPlayer?
    @Published private(set) var nowPlayingTitle: String?
    @Published private(set) var nowPlayingItem: PlexMetadata?
    @Published var isPlayerMinimized = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var quality: PlexQuality = PlexPreferences.shared.preferredQuality
    /// App-level playback volume (0…1), independent of the device volume.
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var isMuted = false

    // Tracks (audio / subtitles) for the currently playing item
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudioID: Int?
    @Published private(set) var currentSubtitleID: Int = -1   // -1 = Off
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?

    // Sheets
    @Published var showLibraryPicker = false
    @Published var showQueue = false
    @Published var showSettings = false
    @Published var infoItem: PlexMetadata?
    @Published var deleteError: String?

    let api = PlexAPI()
    let prefs = PlexPreferences.shared
    private var baseURL: URL?
    private var serverToken: String?
    private var connectionCache: [String: (base: URL, token: String)] = [:]
    private var pollTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    // Live scrubbing (chase-time coalescing so drags don't flood seeks).
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .zero
    private var wasPlayingBeforeScrub = false

    // Playback bookkeeping
    private var playbackGeneration = 0           // guards against superseded startPlayback calls
    private var activeTranscodeSession: String?  // to stop the transcode on teardown
    private var lastTimelineReport = Date.distantPast

    // Play queue
    @Published private(set) var playQueue: [PlexMetadata] = []
    @Published private(set) var queueIndex = 0

    nonisolated init() {}

    private var authToken: String? {
        get { KeychainHelper.get("plex.authToken") }
        set {
            if let newValue { KeychainHelper.set(newValue, for: "plex.authToken") }
            else { KeychainHelper.delete("plex.authToken") }
        }
    }

    var currentLibrary: PlexLibraryRef? {
        if case .library(let ref) = mode { return ref }
        return nil
    }

    var isShowLibrary: Bool { currentLibrary?.type == "show" }

    var navTitle: String { currentLibrary?.title ?? "Home" }

    // MARK: Lifecycle / auth

    func start() {
        guard case .signedOut = phase else { return }
        if authToken != nil { Task { await connect() } }
    }

    func beginLinking() {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let pin = try await api.createPin()
                phase = .linking(code: pin.code)
                SystemBrowser.open(api.linkPageURL)
                try await pollForToken(pinID: pin.id)
            } catch is CancellationError {
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func reopenLinkPage() { SystemBrowser.open(api.linkPageURL) }

    func cancelLinking() {
        pollTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        pollTask?.cancel()
        authToken = nil
        KeychainHelper.delete("plex.lastConnection")
        ImageCache.shared.clear()
        PlexBrowseCache.shared.clear()
        baseURL = nil
        serverToken = nil
        connectionCache = [:]
        servers = []
        selectedServer = nil
        sections = []
        onDeck = []
        recentlyAdded = []
        serverLibraries = [:]
        mode = .home
        stack = []
        recommendedHubs = []
        browseItems = []
        playlists = []
        libraryLoadState = .idle
        closePlayer()
        phase = .signedOut
    }

    private func pollForToken(pinID: Int) async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let pin = try? await api.checkPin(id: pinID) else { continue }
            if let token = pin.authToken, !token.isEmpty {
                authToken = token
                await connect()
                return
            }
        }
        phase = .error("Timed out waiting for Plex sign-in.")
    }

    // MARK: Servers

    func connect() async {
        guard let token = authToken else { phase = .signedOut; return }

        // Fast path: reuse the last-good connection, validated with a quick
        // probe, and refresh the server list in the background.
        if let cached = loadCachedConnection(), let base = URL(string: cached.baseURL) {
            phase = .loading("Reconnecting to \(cached.serverName)…")
            if await api.probe(base: base, token: cached.token) {
                baseURL = base
                serverToken = cached.token
                connectionCache[cached.serverID] = (base, cached.token)
                await loadHome()
                Task { await refreshServers(preferredID: cached.serverID) }
                return
            }
        }

        phase = .loading("Finding your servers…")
        do {
            let all = try await api.resources(token: token).filter { $0.isServer }
            servers = all
            guard let first = all.first else {
                phase = .error("No Plex servers found on this account.")
                return
            }
            await select(server: first)
        } catch {
            phase = .error(classify(error))
        }
    }

    /// Refresh the server list without disturbing the active connection.
    private func refreshServers(preferredID: String?) async {
        guard let token = authToken,
              let all = try? await api.resources(token: token).filter({ $0.isServer }) else { return }
        servers = all
        if selectedServer == nil, let preferredID {
            selectedServer = all.first { $0.clientIdentifier == preferredID }
        }
    }

    private func loadCachedConnection() -> PlexCachedConnection? {
        guard let raw = KeychainHelper.get("plex.lastConnection"),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlexCachedConnection.self, from: data)
    }

    private func saveCachedConnection(serverID: String, name: String, base: URL, token: String) {
        connectionCache[serverID] = (base, token)
        let cached = PlexCachedConnection(serverID: serverID, serverName: name,
                                          baseURL: base.absoluteString, token: token)
        if let data = try? JSONEncoder().encode(cached), let raw = String(data: data, encoding: .utf8) {
            KeychainHelper.set(raw, for: "plex.lastConnection")
        }
    }

    private func connection(for serverID: String) async -> (base: URL, token: String)? {
        if let cached = connectionCache[serverID] { return cached }
        guard let server = servers.first(where: { $0.clientIdentifier == serverID }),
              let reachable = await api.reachableBaseURL(for: server) else { return nil }
        connectionCache[serverID] = reachable
        return reachable
    }

    func select(server: PlexResource) async {
        selectedServer = server
        phase = .loading("Connecting to \(server.name)…")
        guard let conn = await connection(for: server.clientIdentifier) else {
            phase = .error("Couldn't reach \(server.name).")
            return
        }
        baseURL = conn.base
        serverToken = conn.token
        saveCachedConnection(serverID: server.clientIdentifier, name: server.name, base: conn.base, token: conn.token)
        await loadHome()
    }

    func loadHome() async {
        guard let base = baseURL, let token = serverToken else { return }
        phase = .loading("Loading your library…")
        mode = .home
        stack = []
        async let deck = try? api.onDeck(base: base, token: token)
        async let recent = try? api.recentlyAdded(base: base, token: token)
        async let secs = try? api.sections(base: base, token: token)
        onDeck = await deck ?? []
        recentlyAdded = await recent ?? []
        sections = await secs ?? []
        phase = .browsing
    }

    func loadAllServerLibraries() {
        for server in servers where serverLibraries[server.clientIdentifier] == nil {
            Task {
                guard let conn = await connection(for: server.clientIdentifier) else { return }
                if let secs = try? await api.sections(base: conn.base, token: conn.token) {
                    serverLibraries[server.clientIdentifier] = secs
                }
            }
        }
    }

    func makeRef(server: PlexResource, section: PlexDirectory) -> PlexLibraryRef {
        PlexLibraryRef(serverID: server.clientIdentifier, serverName: server.name,
                       sectionKey: section.key, title: section.title, type: section.type)
    }

    // MARK: Home / library selection

    func selectHome() {
        showLibraryPicker = false
        Task { await loadHome() }
    }

    func select(library ref: PlexLibraryRef) {
        showLibraryPicker = false
        Task {
            phase = .loading("Loading \(ref.title)…")
            guard let conn = await connection(for: ref.serverID) else {
                phase = .error("Couldn't reach \(ref.serverName).")
                return
            }
            baseURL = conn.base
            serverToken = conn.token
            selectedServer = servers.first { $0.clientIdentifier == ref.serverID }
            saveCachedConnection(serverID: ref.serverID, name: ref.serverName, base: conn.base, token: conn.token)
            mode = .library(ref)
            stack = []
            searchText = ""
            // Restore the remembered sort field and its remembered/default direction.
            sortField = prefs.sortField
            sortAscending = prefs.ascending(for: sortField)
            tvEpisodes = false
            recommendedHubs = []
            browseItems = []
            playlists = []
            libraryTab = .recommended
            phase = .browsing
            loadLibraryTab()
        }
    }

    func openHomeSection(_ section: PlexDirectory) {
        guard let server = selectedServer else { return }
        select(library: makeRef(server: server, section: section))
    }

    // MARK: Library tabs

    func setLibraryTab(_ tab: LibraryTab) {
        libraryTab = tab
        // Driven by a Picker binding; defer the load off the view-update cycle.
        Task { loadLibraryTab() }
    }

    func loadLibraryTab() {
        switch libraryTab {
        case .recommended: loadRecommended()
        case .browse: loadBrowse()
        case .playlists: loadPlaylists()
        }
    }

    func loadRecommended() {
        guard let ref = currentLibrary, let base = baseURL, let token = serverToken else { return }
        tabLoading = true
        recommendedHubs = []
        let start = Date()
        recommendedNet = NetStat(label: "Recommended", path: "/hubs/sections/\(ref.sectionKey)",
                                 phase: "connecting")
        Task {
            do {
                let hubs = try await api.hubs(
                    base: base, token: token, sectionKey: ref.sectionKey,
                    onResponse: { [weak self] status in
                        Task { @MainActor in
                            self?.recommendedNet.httpStatus = status
                            self?.recommendedNet.responseSeconds = Date().timeIntervalSince(start)
                            self?.recommendedNet.phase = "downloading"
                        }
                    },
                    onProgress: { [weak self] bytes in
                        Task { @MainActor in self?.recommendedNet.bytes = bytes }
                    }
                )
                recommendedHubs = hubs.filter { ($0.metadata?.isEmpty == false) }
                recommendedNet.phase = "done"
                recommendedNet.finishedSeconds = Date().timeIntervalSince(start)
            } catch {
                recommendedNet.phase = "failed"
                recommendedNet.error = classify(error)
                recommendedNet.finishedSeconds = Date().timeIntervalSince(start)
            }
            tabLoading = false
        }
    }

    func loadPlaylists() {
        guard let base = baseURL, let token = serverToken else { return }
        tabLoading = true
        Task {
            playlists = (try? await api.playlists(base: base, token: token)) ?? []
            tabLoading = false
        }
    }

    func loadBrowse() {
        guard let ref = currentLibrary, let base = baseURL, let token = serverToken else { return }
        let type: Int? = ref.type == "show" ? (tvEpisodes ? 4 : 2) : nil
        let sort = sortField.key + (sortAscending ? ":asc" : ":desc")
        let cacheKey = "\(ref.id)|type=\(type ?? -1)|sort=\(sort)"
        browseKey = cacheKey
        browseHasMore = false

        // Show cached items immediately (if any) while we refresh in the
        // background; otherwise show the connecting indicator.
        if let cached = PlexBrowseCache.shared.load(cacheKey), !cached.isEmpty {
            browseItems = cached
            libraryLoadState = .ready
        } else {
            browseItems = []
            libraryLoadState = .connecting
        }

        let start = Date()
        browseNet = NetStat(label: "Browse",
                            path: "/library/sections/\(ref.sectionKey)/all (page 0, size \(browsePageSize))",
                            phase: "connecting")

        Task {
            do {
                let items = try await api.sectionItems(
                    base: base, token: token, sectionKey: ref.sectionKey,
                    type: type, sort: sort, start: 0, size: browsePageSize,
                    onResponse: { [weak self] status in
                        Task { @MainActor in
                            guard let self else { return }
                            self.browseNet.httpStatus = status
                            self.browseNet.responseSeconds = Date().timeIntervalSince(start)
                            self.browseNet.phase = "downloading"
                            if self.libraryLoadState == .connecting { self.libraryLoadState = .downloading }
                        }
                    },
                    onProgress: { [weak self] bytes in
                        Task { @MainActor in self?.browseNet.bytes = bytes }
                    }
                )
                guard browseKey == cacheKey else { return } // a newer request superseded us
                browseItems = items
                browseHasMore = items.count >= browsePageSize
                libraryLoadState = .ready
                browseNet.phase = "done"
                browseNet.finishedSeconds = Date().timeIntervalSince(start)
                PlexBrowseCache.shared.save(cacheKey, items: items)
            } catch {
                browseNet.phase = "failed"
                browseNet.error = classify(error)
                browseNet.finishedSeconds = Date().timeIntervalSince(start)
                // Keep showing cached results if we have them; only surface the
                // error when there's nothing to display.
                if browseItems.isEmpty { libraryLoadState = .failed(classify(error)) }
            }
        }
    }

    /// Loads the next page when the user scrolls near the end of Browse.
    func loadMoreBrowseIfNeeded(currentItem item: PlexMetadata) {
        guard browseHasMore, !browseLoadingMore,
              let index = browseItems.firstIndex(where: { $0.id == item.id }),
              index >= browseItems.count - 24,
              let ref = currentLibrary, let base = baseURL, let token = serverToken else { return }

        let type: Int? = ref.type == "show" ? (tvEpisodes ? 4 : 2) : nil
        let sort = sortField.key + (sortAscending ? ":asc" : ":desc")
        let key = browseKey
        let startIndex = browseItems.count
        browseLoadingMore = true
        let start = Date()
        browseNet.path = "/library/sections/\(ref.sectionKey)/all (page @\(startIndex))"
        browseNet.phase = "downloading"

        Task {
            defer { browseLoadingMore = false }
            do {
                let more = try await api.sectionItems(
                    base: base, token: token, sectionKey: ref.sectionKey,
                    type: type, sort: sort, start: startIndex, size: browsePageSize,
                    onProgress: { [weak self] bytes in Task { @MainActor in self?.browseNet.bytes = bytes } }
                )
                guard browseKey == key else { return }
                browseItems.append(contentsOf: more)
                browseHasMore = more.count >= browsePageSize
                browseNet.phase = "done"
                browseNet.finishedSeconds = Date().timeIntervalSince(start)
            } catch {
                browseNet.phase = "failed"
                browseNet.error = classify(error)
            }
        }
    }

    // MARK: Search

    /// Items to show in Browse: search results when a search is active.
    var displayedBrowseItems: [PlexMetadata] { searchActive ? searchResults : browseItems }

    func clearSearch() { searchText = "" }

    /// Debounced; all state changes happen inside the Task so they never fire
    /// during the text field's view update.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            if query.isEmpty {
                searchActive = false
                searching = false
                searchResults = []
                return
            }
            searchActive = true
            searching = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let ref = currentLibrary, let base = baseURL, let token = serverToken else {
                searching = false
                return
            }
            let type: Int? = ref.type == "show" ? (tvEpisodes ? 4 : 2) : nil
            let results = (try? await api.searchLibrary(base: base, token: token,
                                                        sectionKey: ref.sectionKey,
                                                        type: type, query: query)) ?? []
            if Task.isCancelled { return }
            searchResults = results
            searching = false
        }
    }

    // These are driven by Picker bindings, so defer the reload out of the
    // current view-update cycle to avoid "publishing changes from within view
    // updates" warnings.
    func setSortField(_ field: PlexSortField) {
        sortField = field
        // Switching field recalls that field's remembered (or default) direction.
        sortAscending = prefs.ascending(for: field)
        prefs.setSortField(field)
        Task { loadBrowse() }
    }

    func setSortAscending(_ ascending: Bool) {
        sortAscending = ascending
        prefs.setAscending(ascending, for: sortField)
        Task { loadBrowse() }
    }

    func setTVEpisodes(_ episodes: Bool) { tvEpisodes = episodes; Task { loadBrowse() } }

    // MARK: Drill-down

    func open(item: PlexMetadata) {
        if item.isPlaylist { openPlaylist(item); return }
        if item.isPlayable { playSingle(item); return }
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            if let children = try? await api.children(base: base, token: token, ratingKey: item.ratingKey) {
                stack.append(BrowseLevel(title: item.title, items: children))
            }
        }
    }

    func openPlaylist(_ item: PlexMetadata) {
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            if let items = try? await api.playlistItems(base: base, token: token, ratingKey: item.ratingKey) {
                stack.append(BrowseLevel(title: item.title, items: items))
            }
        }
    }

    func back() {
        if !stack.isEmpty { stack.removeLast() } else { selectHome() }
    }

    // MARK: Images

    func imageURL(for path: String?) -> URL? {
        guard let base = baseURL, let token = serverToken else { return nil }
        return api.imageURL(base: base, token: token, path: path)
    }

    // MARK: Playback

    func playSingle(_ item: PlexMetadata) {
        playQueue = [item]
        queueIndex = 0
        Task { await startPlayback(item, resumeAt: nil) }
    }

    func playAll(_ items: [PlexMetadata], shuffle: Bool) {
        var queue = items.filter { $0.isPlayable }
        guard !queue.isEmpty else { return }
        if shuffle { queue.shuffle() }
        playQueue = queue
        queueIndex = 0
        Task { await startPlayback(queue[0], resumeAt: nil) }
    }

    /// Queue `item` to play right after the current one (or start it if nothing
    /// is playing).
    func playNext(_ item: PlexMetadata) {
        guard item.isPlayable else { return }
        guard player != nil else { playSingle(item); return }
        playQueue.insert(item, at: min(queueIndex + 1, playQueue.count))
    }

    /// Append `item` to the end of the queue (or start it if nothing is playing).
    func addToQueue(_ item: PlexMetadata) {
        guard item.isPlayable else { return }
        guard player != nil else { playSingle(item); return }
        playQueue.append(item)
    }

    /// Number of items still queued after the current one.
    var upNextCount: Int { max(0, playQueue.count - queueIndex - 1) }

    private func advanceQueue() {
        queueIndex += 1
        if queueIndex < playQueue.count {
            let next = playQueue[queueIndex]
            Task { await startPlayback(next, resumeAt: nil) }
        } else {
            closePlayer()
        }
    }

    private func startPlayback(_ requested: PlexMetadata, resumeAt: CMTime?) async {
        guard let base = baseURL, let token = serverToken else { return }

        // Guard against superseded calls (rapid next/next, quality change mid-fetch).
        playbackGeneration += 1
        let generation = playbackGeneration

        // Ensure we know the real container/codecs before deciding direct-play
        // vs transcode; list metadata often omits them.
        var item = requested
        if item.partContainer == nil, let detailed = try? await api.metadata(base: base, token: token, ratingKey: item.ratingKey) {
            item = detailed
        }
        guard generation == playbackGeneration else { return } // a newer call won

        let session = UUID().uuidString
        let transcoding = api.willTranscode(item: item, quality: quality)
        guard let url = api.playbackURL(base: base, token: token, item: item, quality: quality, session: session) else { return }

        // Report the outgoing item as stopped and stop its transcode session.
        reportTimeline("stopped")
        stopActiveTranscode()

        // Fully stop the outgoing player so its audio doesn't keep playing
        // while the new item takes over.
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let existing = self.player {
            if let timeObserver { existing.removeTimeObserver(timeObserver) }
            timeObserver = nil
            existing.pause()
            existing.replaceCurrentItem(with: nil)
        }
        currentTime = 0
        duration = 0
        activeTranscodeSession = transcoding ? session : nil

        let player = AVPlayer(url: url)
        observeTime(player)
        if let resumeAt {
            player.seek(to: resumeAt) { _ in }
        } else if let offsetMs = item.viewOffset, offsetMs > 0 {
            player.seek(to: CMTime(seconds: Double(offsetMs) / 1000.0, preferredTimescale: 600)) { _ in }
        }
        player.volume = Float(volume)
        player.isMuted = isMuted
        nowPlayingItem = item
        nowPlayingTitle = item.type == "episode"
            ? [item.grandparentTitle, item.title].compactMap { $0 }.joined(separator: " — ")
            : item.title
        observePlayback(player)
        observeEnd(of: player)
        withAnimation(.easeInOut(duration: 0.25)) {
            self.player = player
            isPlayerMinimized = false
        }
        player.play()
        reportTimeline("playing")
        if let currentItem = player.currentItem {
            Task { await loadTracks(for: currentItem) }
        }
    }

    // MARK: Timeline / transcode session

    private func reportTimeline(_ state: String) {
        guard let base = baseURL, let token = serverToken, let item = nowPlayingItem else { return }
        lastTimelineReport = Date()
        let timeMs = Int(currentTime * 1000)
        let durationMs = Int(duration * 1000)
        Task {
            await api.reportTimeline(base: base, token: token,
                                     ratingKey: item.ratingKey, key: item.key,
                                     state: state, timeMs: timeMs, durationMs: durationMs)
        }
    }

    private func stopActiveTranscode() {
        guard let session = activeTranscodeSession, let base = baseURL, let token = serverToken else { return }
        activeTranscodeSession = nil
        Task { await api.stopTranscode(base: base, token: token, session: session) }
    }

    // MARK: Audio / subtitle tracks

    private func loadTracks(for item: AVPlayerItem) async {
        audioTracks = []
        subtitleTracks = [MediaTrack(id: -1, name: "Off")]
        currentAudioID = nil
        currentSubtitleID = -1
        audioGroup = nil
        subtitleGroup = nil

        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = group
            audioTracks = group.options.enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                currentAudioID = index
            } else {
                currentAudioID = audioTracks.first?.id
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleGroup = group
            subtitleTracks = [MediaTrack(id: -1, name: "Off")]
                + group.options.enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                currentSubtitleID = index
            } else {
                currentSubtitleID = -1
            }
        }
    }

    func selectAudio(_ id: Int) {
        guard let group = audioGroup, group.options.indices.contains(id),
              let item = player?.currentItem else { return }
        item.select(group.options[id], in: group)
        currentAudioID = id
    }

    func selectSubtitle(_ id: Int) {
        guard let group = subtitleGroup, let item = player?.currentItem else { return }
        if id < 0 {
            item.select(nil, in: group)
            currentSubtitleID = -1
        } else if group.options.indices.contains(id) {
            item.select(group.options[id], in: group)
            currentSubtitleID = id
        }
    }

    // MARK: Queue management

    var hasPreviousInQueue: Bool { queueIndex > 0 }
    var hasNextInQueue: Bool { queueIndex < playQueue.count - 1 }

    func playPreviousInQueue() {
        guard hasPreviousInQueue else { return }
        playQueueItem(at: queueIndex - 1)
    }

    func playNextInQueue() {
        guard hasNextInQueue else { return }
        playQueueItem(at: queueIndex + 1)
    }

    func playQueueItem(at index: Int) {
        guard playQueue.indices.contains(index) else { return }
        queueIndex = index
        let item = playQueue[index]
        Task { await startPlayback(item, resumeAt: nil) }
    }

    func removeFromQueue(at index: Int) {
        guard playQueue.indices.contains(index), index != queueIndex else { return }
        playQueue.remove(at: index)
        if index < queueIndex { queueIndex -= 1 }
    }

    private func observePlayback(_ player: AVPlayer) {
        statusObservation?.invalidate()
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    private func observeTime(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                if seconds.isFinite { self.currentTime = seconds }
                if let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                // Report progress to Plex ~every 10s while playing.
                if self.isPlaying, Date().timeIntervalSince(self.lastTimelineReport) >= 10 {
                    self.reportTimeline("playing")
                }
            }
        }
    }

    /// Seek to a fraction (0…1) of the item's duration.
    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    // MARK: Live scrubbing

    func beginScrub() {
        wasPlayingBeforeScrub = player?.timeControlStatus == .playing
        player?.pause()
    }

    /// Called continuously as the scrubber is dragged — seeks the video live.
    func scrub(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        currentTime = target
        chaseTime = CMTime(seconds: target, preferredTimescale: 600)
        if !isSeekInProgress { seekToChaseTime() }
    }

    func endScrub(toFraction fraction: Double) {
        scrub(toFraction: fraction)
        if wasPlayingBeforeScrub { player?.play() }
    }

    private func seekToChaseTime() {
        guard let player else { isSeekInProgress = false; return }
        isSeekInProgress = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CMTimeCompare(self.chaseTime, target) == 0 {
                    self.isSeekInProgress = false
                } else {
                    self.seekToChaseTime()
                }
            }
        }
    }

    func skip(by seconds: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(duration, currentTime + seconds))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func observeEnd(of player: AVPlayer) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceQueue() }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            reportTimeline("paused")
        } else {
            player.play()
            reportTimeline("playing")
        }
    }

    /// In-app volume, independent of the device's hardware volume.
    func setVolume(_ newValue: Double) {
        volume = max(0, min(1, newValue))
        player?.volume = Float(volume)
        if volume > 0 && isMuted {
            isMuted = false
            player?.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func minimizePlayer() { withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = true } }
    func expandPlayer() { withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = false } }

    func closePlayer() {
        reportTimeline("stopped")
        stopActiveTranscode()
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        currentTime = 0
        duration = 0
        player?.pause()
        withAnimation(.easeInOut(duration: 0.25)) {
            player = nil
            isPlayerMinimized = false
        }
        nowPlayingTitle = nil
        nowPlayingItem = nil
        isPlaying = false
        playQueue = []
        queueIndex = 0
        audioTracks = []
        subtitleTracks = []
        currentAudioID = nil
        currentSubtitleID = -1
        audioGroup = nil
        subtitleGroup = nil
    }

    func setQuality(_ newQuality: PlexQuality) {
        guard newQuality != quality else { return }
        quality = newQuality
        guard let item = nowPlayingItem, let player else { return }
        let resume = player.currentTime()
        Task { await startPlayback(item, resumeAt: resume) }
    }

    func presentInfo() {
        guard let item = nowPlayingItem else { return }
        if let base = baseURL, let token = serverToken {
            Task {
                let detailed = (try? await api.metadata(base: base, token: token, ratingKey: item.ratingKey)) ?? item
                infoItem = detailed
            }
        } else {
            infoItem = item
        }
    }

    /// Sets the default streaming rate used for new playback (persisted).
    func setPreferredStreamingRate(_ newQuality: PlexQuality) {
        prefs.setPreferredQuality(newQuality)
        quality = newQuality
    }

    // MARK: Delete

    func deleteFromPlex(_ item: PlexMetadata) {
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            do {
                try await api.deleteItem(base: base, token: token, ratingKey: item.ratingKey)
                // Remove it from anything currently on screen.
                browseItems.removeAll { $0.id == item.id }
                searchResults.removeAll { $0.id == item.id }
                if !stack.isEmpty { stack[stack.count - 1].items.removeAll { $0.id == item.id } }
                infoItem = nil
            } catch {
                infoItem = nil
                if case PlexError.http(let code) = error, code == 401 || code == 403 {
                    deleteError = "Deletion is disabled on this server. Enable “Allow media deletion” in the Plex server settings."
                } else {
                    deleteError = "Couldn't delete this item. \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Error classification

    private func classify(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return "No response from the server (couldn't connect)."
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Container view

struct PlexPlayerContainerView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        ZStack {
            Palette.windowBackground
            content
                .safeAreaInset(edge: .bottom) { miniBar }
        }
        .overlay { fullPlayer }
        .sheet(isPresented: $model.showLibraryPicker) { LibraryPickerView(model: model) }
        .sheet(isPresented: $model.showQueue) { QueueView(model: model) }
        .sheet(isPresented: $model.showSettings) { PlexSettingsView(model: model) }
        .sheet(item: $model.infoItem) { item in MediaInfoView(model: model, item: item) }
        .alert("Delete Failed",
               isPresented: Binding(get: { model.deleteError != nil },
                                    set: { if !$0 { model.deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.deleteError ?? "")
        }
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            SignInView(model: model)
        case .linking(let code):
            LinkingView(model: model, code: code)
        case .loading(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ErrorView(model: model, message: message)
        case .browsing:
            BrowseView(model: model)
        }
    }

    @ViewBuilder
    private var miniBar: some View {
        if model.player != nil && model.isPlayerMinimized {
            MiniPlayerBar(model: model).transition(.move(edge: .bottom))
        }
    }

    @ViewBuilder
    private var fullPlayer: some View {
        if model.player != nil && !model.isPlayerMinimized {
            FullPlayerView(model: model).transition(.opacity)
        }
    }
}

// MARK: - Sign-in / linking / error

private struct SignInView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill").font(.system(size: 56)).foregroundStyle(.orange)
            Text("Plex Player").font(.title2).bold()
            Text("Sign in to browse and play your Plex library natively.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Sign in to Plex") { model.beginLinking() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct LinkingView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let code: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Waiting for Plex sign-in…").font(.headline)
            Text("A browser window opened to link this app. If it didn't, go to plex.tv/link and enter this code:")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Text(code.uppercased())
                .font(.system(.largeTitle, design: .monospaced)).bold().tracking(4).textSelection(.enabled)
            HStack {
                Button("Reopen link page") { model.reopenLinkPage() }
                Button("Cancel", role: .cancel) { model.cancelLinking() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct ErrorView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack {
                Button("Retry") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                Button("Sign out") { model.signOut() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Browse

private struct BrowseView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let level = model.stack.last {
                DrillView(model: model, level: level)
            } else if case .library = model.mode {
                LibraryRootView(model: model)
            } else {
                ScrollView { HomeView(model: model) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.showLibraryPicker = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text(model.navTitle).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .help("Choose library")

            if !model.stack.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button { model.back() } label: {
                    Label(model.stack.last?.title ?? "", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            Menu {
                Button("Reload") { model.loadLibraryTab() }
                Button("Settings…") { model.showSettings = true }
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
        }
        .padding(.leading, 12).padding(.vertical, 8)
        // Reserve the top-right corner for the pane's container picker.
        .padding(.trailing, containerPickerReservedWidth)
        .background(.bar)
    }
}

private struct HomeView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.onDeck.isEmpty { HubRail(model: model, title: "On Deck", items: model.onDeck) }
            if !model.recentlyAdded.isEmpty { HubRail(model: model, title: "Recently Added", items: model.recentlyAdded) }
            if !model.sections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libraries").font(.title3).bold()
                    ForEach(model.sections) { section in
                        Button { model.openHomeSection(section) } label: {
                            Label(section.title, systemImage: section.symbolName).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.onDeck.isEmpty && model.recentlyAdded.isEmpty && model.sections.isEmpty {
                Text("Nothing to show yet.").foregroundStyle(.secondary)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Library root (tabbed)

private struct LibraryRootView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.libraryTab }, set: { model.setLibraryTab($0) })) {
                ForEach(PlexPlayerViewModel.LibraryTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            switch model.libraryTab {
            case .recommended: RecommendedTab(model: model)
            case .browse: BrowseTab(model: model)
            case .playlists: PlaylistsTab(model: model)
            }
        }
    }
}

private struct RecommendedTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    var body: some View {
        ZStack(alignment: .bottom) {
            content
            if prefs.showNetworkDebug {
                NetDebugBar(stat: model.recommendedNet).padding(8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.tabLoading && model.recommendedHubs.isEmpty {
            LoadingBanner(text: "Loading recommendations…")
        } else if model.recommendedHubs.isEmpty {
            EmptyBanner(text: "No recommendations for this library.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.recommendedHubs) { hub in
                        HubRail(model: model, title: hub.title ?? "", items: hub.metadata ?? [])
                    }
                }
                .padding()
            }
        }
    }
}

private struct BrowseTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            controls
            Divider()
            ZStack(alignment: .bottom) {
                if model.searchActive { searchContent } else { loadStateContent }
                if prefs.showNetworkDebug {
                    NetDebugBar(stat: model.browseNet).padding(8)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search this library by title", text: $model.searchText)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.selectedControl, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.searching && model.searchResults.isEmpty {
            LoadingBanner(text: "Searching…")
        } else if model.searchResults.isEmpty {
            EmptyBanner(text: "No results for “\(model.searchText)”.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.searchResults) { item in
                        PosterCard(model: model, item: item) { model.open(item: item) }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var loadStateContent: some View {
        switch model.libraryLoadState {
        case .connecting:
            LoadingBanner(text: "Contacting server…")
        case .downloading:
            LoadingBanner(text: "Downloading library…")
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Retry") { model.loadBrowse() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .idle, .ready:
            if model.browseItems.isEmpty {
                EmptyBanner(text: "This library is empty.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.browseItems) { item in
                            PosterCard(model: model, item: item) { model.open(item: item) }
                                .onAppear { model.loadMoreBrowseIfNeeded(currentItem: item) }
                        }
                    }
                    .padding()
                    if model.browseLoadingMore {
                        ProgressView().padding()
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Sort by", selection: Binding(get: { model.sortField }, set: { model.setSortField($0) })) {
                    ForEach(PlexSortField.allCases) { field in Text(field.rawValue).tag(field) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Order", selection: Binding(get: { model.sortAscending }, set: { model.setSortAscending($0) })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(model.sortField.rawValue) \(model.sortAscending ? "↑" : "↓")",
                      systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            if model.isShowLibrary {
                Picker("", selection: Binding(get: { model.tvEpisodes }, set: { model.setTVEpisodes($0) })) {
                    Text("Shows").tag(false)
                    Text("Episodes").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Spacer()

            Button { model.playAll(model.displayedBrowseItems, shuffle: false) } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .disabled(!model.displayedBrowseItems.contains { $0.isPlayable })
            Button { model.playAll(model.displayedBrowseItems, shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(!model.displayedBrowseItems.contains { $0.isPlayable })
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct PlaylistsTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]
    var body: some View {
        if model.tabLoading && model.playlists.isEmpty {
            LoadingBanner(text: "Loading playlists…")
        } else if model.playlists.isEmpty {
            EmptyBanner(text: "No playlists on this server.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.playlists) { playlist in
                        PosterCard(model: model, item: playlist, width: 150) { model.openPlaylist(playlist) }
                    }
                }
                .padding()
            }
        }
    }
}

private struct DrillView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let level: PlexPlayerViewModel.BrowseLevel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            if level.items.contains(where: { $0.isPlayable }) {
                HStack {
                    Button { model.playAll(level.items, shuffle: false) } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    Button { model.playAll(level.items, shuffle: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding([.horizontal, .top])
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(level.items) { item in
                    PosterCard(model: model, item: item) { model.open(item: item) }
                }
            }
            .padding()
        }
    }
}

// MARK: - Reusable rows / cards / banners

private struct HubRail: View {
    @ObservedObject var model: PlexPlayerViewModel
    let title: String
    let items: [PlexMetadata]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PosterCard(model: model, item: item, width: 130) { model.open(item: item) }
                    }
                }
            }
        }
    }
}

private struct PosterCard: View {
    @ObservedObject var model: PlexPlayerViewModel
    let item: PlexMetadata
    var width: CGFloat = 140
    let action: () -> Void

    var body: some View {
        // Only playable items get a context menu, so a long-press on a
        // folder/show doesn't lift an empty menu.
        if item.isPlayable {
            card.contextMenu {
                Button { action() } label: { Label("Play", systemImage: "play.fill") }
                Button { model.playNext(item) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { model.addToQueue(item) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
            }
        } else {
            card
        }
    }

    private var card: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Palette.selectedControl)
                    CachedAsyncImage(url: model.imageURL(for: item.posterPath)) {
                        Image(systemName: placeholderSymbol).font(.largeTitle).foregroundStyle(.secondary)
                    }
                    if item.isPlayable {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
                    }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title).font(.caption).bold().lineLimit(1).frame(width: width, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
            .frame(width: width)
            // Make the whole card one hit target — including the poster's
            // rounded-corner gaps and any transparent areas.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placeholderSymbol: String {
        if item.isPlaylist { return "music.note.list" }
        return item.isPlayable ? "play.rectangle" : "square.stack"
    }
}

private struct LoadingBanner: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct EmptyBanner: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

/// Compact network diagnostics overlay for the Recommended / Browse fetches.
private struct NetDebugBar: View {
    let stat: NetStat

    private var tint: Color {
        switch stat.phase {
        case "failed": return .red
        case "done": return .green
        case "idle": return .gray
        default: return .yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text("NET · \(stat.label)").bold()
                Spacer()
                Text(stat.statusLine)
            }
            Text(stat.path).foregroundStyle(.secondary).lineLimit(1)
            Text(stat.detailLine)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Library picker sheet

private struct LibraryPickerView: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { model.selectHome() } label: { Label("Home", systemImage: "house") }
                }

                Section("Favorites") {
                    if prefs.favorites.isEmpty {
                        Text("No favorites yet. Tap the heart next to a library below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(prefs.favorites) { ref in
                            LibraryRow(ref: ref, isFavorite: true,
                                       onSelect: { model.select(library: ref) },
                                       onToggleFavorite: { prefs.toggleFavorite(ref) })
                        }
                        .onMove { prefs.move(from: $0, to: $1) }
                    }
                }

                Section("All Libraries") {
                    Button {
                        withAnimation { showAll.toggle() }
                        if showAll { model.loadAllServerLibraries() }
                    } label: {
                        HStack {
                            Label("Browse all servers", systemImage: "square.stack.3d.up")
                            Spacer()
                            Image(systemName: showAll ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // One Section per server so SwiftUI keeps each server's rows
                // distinctly identified (otherwise async loads get mismatched).
                if showAll {
                    ForEach(model.servers) { server in
                        Section {
                            let libs = model.serverLibraries[server.clientIdentifier] ?? []
                            if libs.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(libs) { section in
                                    let ref = model.makeRef(server: server, section: section)
                                    LibraryRow(ref: ref, isFavorite: prefs.isFavorite(ref),
                                               onSelect: { model.select(library: ref) },
                                               onToggleFavorite: { prefs.toggleFavorite(ref) })
                                }
                            }
                        } header: {
                            Label(server.name, systemImage: "server.rack")
                        }
                    }
                }
            }
            .navigationTitle("Libraries")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                #else
                ToolbarItem { Button("Done") { dismiss() } }
                #endif
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

private struct LibraryRow: View {
    let ref: PlexLibraryRef
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) { Label(ref.title, systemImage: ref.symbolName) }
                .buttonStyle(.plain)
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remove favorite" : "Add favorite")
        }
    }
}

// MARK: - Mini player

private struct MiniPlayerBar: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        HStack(spacing: 12) {
            if let player = model.player {
                PlayerLayerView(player: player)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlayingTitle ?? "Now Playing").font(.subheadline).lineLimit(1)
                Text(model.isPlaying ? "Playing" : "Paused").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .help(model.isMuted ? "Unmute" : "Mute")
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            Button { model.expandPlayer() } label: { Image(systemName: "chevron.up").font(.title3) }
                .buttonStyle(.borderless).help("Expand")
            Button { model.closePlayer() } label: { Image(systemName: "xmark").font(.title3) }
                .buttonStyle(.borderless).help("Stop")
        }
        .padding(8).background(.bar).overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { model.expandPlayer() }
    }
}

// MARK: - Full player

private struct FullPlayerView: View {
    @ObservedObject var model: PlexPlayerViewModel

    // Pinch-to-zoom state (centered magnification of the video).
    @State private var zoom: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0
    private let maxZoom: CGFloat = 4.0

    // Scrubber state.
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    // Double-tap seek feedback (nil, or the signed seconds jumped).
    @State private var seekFlash: Int?
    @State private var seekFlashID = UUID()

    private var effectiveScale: CGFloat { min(max(zoom * pinch, 1.0), maxZoom) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = model.player {
                    PlayerLayerView(player: player)
                        .scaleEffect(effectiveScale)
                        .ignoresSafeArea()
                        .gesture(
                            MagnifyGesture()
                                .updating($pinch) { value, state, _ in state = value.magnification }
                                .onEnded { value in
                                    zoom = min(max(zoom * value.magnification, 1.0), maxZoom)
                                    if zoom < 1.05 { zoom = 1.0 }
                                }
                        )
                        // Double-tap left half = back 15s, right half = forward 15s.
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2, coordinateSpace: .named("player"))
                                .onEnded { value in doubleTapSeek(x: value.location.x, width: geo.size.width) }
                        )
                }
                seekFeedbackOverlay
                VStack(spacing: 0) {
                    controlBar
                    Spacer(minLength: 0)
                    transportBar
                }
            }
            .coordinateSpace(name: "player")
        }
        .clipped()
        .animation(.easeOut(duration: 0.15), value: zoom)
    }

    private func doubleTapSeek(x: CGFloat, width: CGFloat) {
        guard model.duration > 0 else { return }
        if x < width / 2 {
            model.skip(by: -15)
            flashSeek(-15)
        } else {
            model.skip(by: 15)
            flashSeek(15)
        }
    }

    private func flashSeek(_ delta: Int) {
        let id = UUID()
        seekFlashID = id
        withAnimation(.easeIn(duration: 0.1)) { seekFlash = delta }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if seekFlashID == id {
                withAnimation(.easeOut(duration: 0.3)) { seekFlash = nil }
            }
        }
    }

    @ViewBuilder
    private var seekFeedbackOverlay: some View {
        if let delta = seekFlash {
            HStack(spacing: 0) {
                ZStack { if delta < 0 { seekBadge(systemName: "gobackward.15") } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ZStack { if delta > 0 { seekBadge(systemName: "goforward.15") } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
    }

    private func seekBadge(systemName: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName).font(.system(size: 46, weight: .semibold))
            Text("15 sec").font(.caption).bold()
        }
        .foregroundStyle(.white)
        .padding(28)
        .background(.black.opacity(0.4), in: Circle())
        .transition(.scale.combined(with: .opacity))
    }

    // Top bar: navigation + settings-style controls.
    private var controlBar: some View {
        HStack(spacing: 16) {
            Button { model.minimizePlayer() } label: { Image(systemName: "chevron.down").font(.title3) }
                .help("Minimize")

            Text(model.nowPlayingTitle ?? "").font(.headline).lineLimit(1)
            Spacer()

            Button { model.presentInfo() } label: { Image(systemName: "info.circle").font(.title3) }
                .help("Media info")

            // Audio / subtitle tracks.
            Menu {
                if model.audioTracks.count > 1 {
                    Picker("Audio", selection: Binding(get: { model.currentAudioID ?? -1 },
                                                       set: { model.selectAudio($0) })) {
                        ForEach(model.audioTracks) { track in Text(track.name).tag(track.id) }
                    }
                    .pickerStyle(.inline)
                }
                Picker("Subtitles", selection: Binding(get: { model.currentSubtitleID },
                                                       set: { model.selectSubtitle($0) })) {
                    ForEach(model.subtitleTracks) { track in Text(track.name).tag(track.id) }
                }
                .pickerStyle(.inline)
                if model.audioTracks.count <= 1 && model.subtitleTracks.count <= 1 {
                    Text("No alternate tracks")
                }
            } label: {
                Image(systemName: "gearshape").font(.title3)
            }
            .menuIndicator(.hidden)
            .help("Audio & subtitles")

            Menu {
                Picker("Quality", selection: Binding(get: { model.quality }, set: { model.setQuality($0) })) {
                    ForEach(PlexQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .menuIndicator(.hidden)
            .help("Playback quality")

            if zoom > 1.01 {
                Button { withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0 } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3)
                }
                .help("Reset zoom")
            }

            Button { model.showQueue = true } label: { Image(systemName: "line.3.horizontal").font(.title3) }
                .help("Queue")

            Button { model.closePlayer() } label: { Image(systemName: "xmark").font(.title3) }
                .help("Stop")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.leading, 20).padding(.vertical, 12)
        // Reserve the top-right corner for the pane's container picker.
        .padding(.trailing, containerPickerReservedWidth + 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // Bottom bar: our own transport (replaces AVKit's built-in controls).
    private var transportBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(timeString(scrubbing ? scrubValue * model.duration : model.currentTime))
                    .font(.caption).monospacedDigit()
                Slider(value: $scrubValue, in: 0...1) { editing in
                    scrubbing = editing
                    if editing { model.beginScrub() }
                    else { model.endScrub(toFraction: scrubValue) }
                }
                .tint(.white)
                .disabled(model.duration <= 0)
                .onChange(of: scrubValue) { _, newValue in
                    if scrubbing { model.scrub(toFraction: newValue) }
                }
                Text(timeString(model.duration)).font(.caption).monospacedDigit()
            }

            HStack(spacing: 22) {
                Button { model.playPreviousInQueue() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!model.hasPreviousInQueue)
                Button { model.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                Button { model.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                Button { model.playNextInQueue() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!model.hasNextInQueue)

                Spacer()

                Button { model.toggleMute() } label: {
                    Image(systemName: model.isMuted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                    .frame(width: 110)
                    .tint(.white)
            }
            .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
        .onChange(of: model.currentTime) { _, _ in
            if !scrubbing, model.duration > 0 { scrubValue = model.currentTime / model.duration }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Queue sheet

private struct QueueView: View {
    @ObservedObject var model: PlexPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    /// How many items to show on each side of the current one.
    private let window = 30

    var body: some View {
        NavigationStack {
            List {
                if model.playQueue.isEmpty {
                    Text("The queue is empty.").foregroundStyle(.secondary)
                } else {
                    let lower = max(0, model.queueIndex - window)
                    let upper = min(model.playQueue.count - 1, model.queueIndex + window)

                    if lower > 0 {
                        Text("\(lower) earlier item\(lower == 1 ? "" : "s") hidden")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(lower...upper, id: \.self) { index in
                        row(index)
                    }
                    let remaining = (model.playQueue.count - 1) - upper
                    if remaining > 0 {
                        Text("\(remaining) more item\(remaining == 1 ? "" : "s") hidden")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Up Next")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func row(_ index: Int) -> some View {
        let item = model.playQueue[index]
        let isCurrent = index == model.queueIndex
        return HStack(spacing: 10) {
            Image(systemName: isCurrent ? "play.fill" : "line.3.horizontal")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isCurrent {
                Text("Now Playing").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.playQueueItem(at: index) }
        .swipeActions {
            if !isCurrent {
                Button(role: .destructive) { model.removeFromQueue(at: index) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Settings sheet

private struct PlexSettingsView: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Preferred streaming rate",
                           selection: Binding(get: { prefs.preferredQuality },
                                              set: { model.setPreferredStreamingRate($0) })) {
                        ForEach(PlexQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Default quality when a video starts. You can still change it during playback.")
                }

                Section("Display") {
                    Toggle("Network debug overlay",
                           isOn: Binding(get: { prefs.showNetworkDebug },
                                         set: { prefs.setShowNetworkDebug($0) }))
                }

                Section {
                    Toggle("Show “Delete from Plex”",
                           isOn: Binding(get: { prefs.showDeleteOption },
                                         set: { prefs.setShowDeleteOption($0) }))
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Adds a delete action to the media info screen. Deleting also requires “Allow media deletion” to be enabled on the Plex server.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 440)
    }
}

// MARK: - Media info sheet

private struct MediaInfoView: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    let item: PlexMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var media: PlexMedia? { item.media?.first }

    var body: some View {
        NavigationStack {
            List {
                Section("Title") {
                    infoRow("Title", item.title)
                    if let subtitle = item.subtitle { infoRow("Details", subtitle) }
                    infoRow("Runtime", item.runtimeText)
                }
                Section("Video") {
                    infoRow("Resolution", resolutionText)
                    infoRow("Codec", media?.videoCodec?.uppercased())
                    infoRow("Frame rate", media?.videoFrameRate)
                    infoRow("Bitrate", media?.bitrate.map { "\($0) kbps" })
                }
                Section("Audio") {
                    infoRow("Codec", media?.audioCodec?.uppercased())
                    infoRow("Channels", media?.audioChannels.map(String.init))
                }
                Section("File") {
                    infoRow("Container", (media?.container ?? item.partContainer)?.uppercased())
                    infoRow("Size", fileSizeText)
                    infoRow("Filename", item.fileName)
                    if let path = item.filePath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Path").font(.caption).foregroundStyle(.secondary)
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if prefs.showDeleteOption {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete from Plex…", systemImage: "trash")
                        }
                    } footer: {
                        Text("Removes the media (and its file) from the server. Requires “Allow media deletion” to be enabled on the server.")
                    }
                }
            }
            .navigationTitle("Media Info")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete “\(item.title)” from Plex? This can't be undone.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteFromPlex(item)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var resolutionText: String? {
        if let w = media?.width, let h = media?.height { return "\(w) × \(h)" }
        return media?.videoResolution?.uppercased()
    }

    private var fileSizeText: String? {
        guard let size = media?.parts?.first?.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Player layer (no system controls)

/// Renders an AVPlayer via a plain `AVPlayerLayer` — no system playback
/// controls — so AVKit's built-in controls don't collide with our overlay.
#if os(macOS)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerLayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#else
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
