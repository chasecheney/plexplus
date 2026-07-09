import Foundation
import Combine

/// Persisted Plex UI preferences shared across panes: the user's favorite
/// libraries (ordered) that appear at the top of the library picker.
final class PlexPreferences: ObservableObject {
    static let shared = PlexPreferences()

    @Published private(set) var favorites: [PlexLibraryRef] = []

    /// The last chosen sort field, remembered across libraries and launches.
    @Published private(set) var sortField: PlexSortField = .name
    /// Per-field sort direction the user has chosen (keyed by field raw value).
    private var sortDirections: [String: Bool] = [:]

    // App settings
    @Published private(set) var showDeleteOption = false
    @Published private(set) var preferredQuality: PlexQuality = .original
    @Published private(set) var showNetworkDebug = false

    private let favoritesKey = "plex.favoriteLibraries"
    private let sortFieldKey = "plex.sortField"
    private let sortDirectionsKey = "plex.sortDirections"
    private let showDeleteKey = "plex.showDeleteOption"
    private let preferredQualityKey = "plex.preferredQuality"
    private let showNetDebugKey = "plex.showNetworkDebug"

    private init() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([PlexLibraryRef].self, from: data) {
            favorites = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: sortFieldKey),
           let field = PlexSortField(rawValue: raw) {
            sortField = field
        }
        if let data = UserDefaults.standard.data(forKey: sortDirectionsKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            sortDirections = decoded
        }
        showDeleteOption = UserDefaults.standard.bool(forKey: showDeleteKey)
        showNetworkDebug = UserDefaults.standard.bool(forKey: showNetDebugKey)
        if let raw = UserDefaults.standard.string(forKey: preferredQualityKey),
           let quality = PlexQuality(rawValue: raw) {
            preferredQuality = quality
        }
    }

    // MARK: App settings

    func setShowDeleteOption(_ value: Bool) {
        showDeleteOption = value
        UserDefaults.standard.set(value, forKey: showDeleteKey)
    }

    func setShowNetworkDebug(_ value: Bool) {
        showNetworkDebug = value
        UserDefaults.standard.set(value, forKey: showNetDebugKey)
    }

    func setPreferredQuality(_ quality: PlexQuality) {
        preferredQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: preferredQualityKey)
    }

    // MARK: Sorting

    /// Default direction when the user hasn't chosen one: Name ascending,
    /// Release Date / Date Added descending.
    func defaultAscending(for field: PlexSortField) -> Bool { field == .name }

    /// The remembered (or default) direction for a field.
    func ascending(for field: PlexSortField) -> Bool {
        sortDirections[field.rawValue] ?? defaultAscending(for: field)
    }

    func setSortField(_ field: PlexSortField) {
        sortField = field
        UserDefaults.standard.set(field.rawValue, forKey: sortFieldKey)
    }

    func setAscending(_ ascending: Bool, for field: PlexSortField) {
        sortDirections[field.rawValue] = ascending
        if let data = try? JSONEncoder().encode(sortDirections) {
            UserDefaults.standard.set(data, forKey: sortDirectionsKey)
        }
    }

    func isFavorite(_ ref: PlexLibraryRef) -> Bool {
        favorites.contains { $0.id == ref.id }
    }

    func toggleFavorite(_ ref: PlexLibraryRef) {
        if let index = favorites.firstIndex(where: { $0.id == ref.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(ref)
        }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }
}
