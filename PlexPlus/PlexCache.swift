import SwiftUI
import CryptoKit
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

private func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Thumbnail cache

/// Two-tier image cache (memory + disk) for Plex artwork, so posters don't
/// re-download on every scroll or relaunch.
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, PlatformImage>()
    private let directory: URL
    private let session: URLSession

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("PlexThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 600
        let config = URLSessionConfiguration.default
        // Don't let the shared URLCache persist poster URLs (they embed the
        // Plex token); we manage our own token-free disk cache below.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Clears the in-memory and on-disk thumbnail caches (e.g. on sign-out).
    func clear() {
        memory.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func image(for url: URL) async -> PlatformImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }

        let file = directory.appendingPathComponent(sha256Hex(url.absoluteString))
        if let data = try? Data(contentsOf: file), let image = PlatformImage(data: data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = PlatformImage(data: data) else { return nil }
            memory.setObject(image, forKey: url as NSURL)
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            return nil
        }
    }
}

/// Drop-in replacement for `AsyncImage` that reads through `ImageCache`
/// (memory → disk → network) and fills its frame.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ImageCache.shared.image(for: url)
            if !Task.isCancelled { image = loaded }
        }
    }
}

// MARK: - Browse cache

/// Persists a library's browse results to disk so reopening a library is
/// instant; the fresh copy is fetched in the background and replaces it.
final class PlexBrowseCache {
    static let shared = PlexBrowseCache()

    private let directory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("PlexBrowse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(sha256Hex(key) + ".json")
    }

    func load(_ key: String) -> [PlexMetadata]? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? JSONDecoder().decode([PlexMetadata].self, from: data)
    }

    func save(_ key: String, items: [PlexMetadata]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = file(for: key)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    /// Removes all cached browse JSON (e.g. on sign-out).
    func clear() {
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}
