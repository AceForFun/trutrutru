import SwiftUI
import WebKit
import AVFoundation

struct AudioTrack: Decodable, Identifiable, Hashable {
    let id: Int
    let ownerID: Int
    let artist: String
    let title: String
    let duration: Int?
    let url: String?
    let accessKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case artist
        case title
        case duration
        case url
        case accessKey = "access_key"
    }
}

private struct VKAudioResponse: Decodable {
    let response: VKAudioItems
}

private struct VKAudioItems: Decodable {
    let items: [AudioTrack]
}

private struct VKAudioSearchResponse: Decodable {
    let response: VKAudioSearchItems
}

private struct VKAudioSearchItems: Decodable {
    let count: Int?
    let items: [AudioTrack]
}

struct VKRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppScreen {
    case auth
    case songs
}

final class VKAuthStore: ObservableObject {
    private let tokenStorageKey = "vk_access_token"

    @Published var accessToken: String = ""
    @Published var tracks: [AudioTrack] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var deletingTrackIDs: Set<Int> = []

    init() {
        accessToken = UserDefaults.standard.string(forKey: tokenStorageKey) ?? ""
    }

    var screen: AppScreen {
        accessToken.isEmpty ? .auth : .songs
    }

    func saveToken(_ token: String) {
        accessToken = token
        UserDefaults.standard.set(token, forKey: tokenStorageKey)
        errorMessage = nil
        fetchTracks()
    }

    func logout() {
        accessToken = ""
        UserDefaults.standard.removeObject(forKey: tokenStorageKey)
        tracks = []
        errorMessage = nil
    }

    func fetchTracks() {
        guard !accessToken.isEmpty else {
            return
        }

        isLoading = true

        let encodedToken = accessToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? accessToken
        let urlString = "https://api.vk.com/method/audio.get?access_token=\(encodedToken)&v=5.131"

        guard let url = URL(string: urlString) else {
            isLoading = false
            errorMessage = "Некорректный URL для запроса аудио."
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.tracks = []
                    self.errorMessage = "Не удалось загрузить список песен: \(error.localizedDescription)"
                    return
                }

                guard let data = data else {
                    self.tracks = []
                    self.errorMessage = "Не удалось загрузить список песен: пустой ответ."
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(VKAudioResponse.self, from: data)
                    self.tracks = decoded.response.items
                    self.errorMessage = nil
                } catch {
                    self.tracks = []
                    self.errorMessage = "Не удалось загрузить список песен: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func deleteTrack(_ track: AudioTrack) {
        guard !accessToken.isEmpty else { return }
        guard !deletingTrackIDs.contains(track.id) else { return }

        deletingTrackIDs.insert(track.id)

        var components = URLComponents(string: "https://api.vk.com/method/audio.delete")
        components?.queryItems = [
            URLQueryItem(name: "audio_id", value: String(track.id)),
            URLQueryItem(name: "owner_id", value: String(track.ownerID)),
            URLQueryItem(name: "access_key", value: track.accessKey),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "v", value: "5.131")
        ]

        guard let url = components?.url else {
            DispatchQueue.main.async {
                self.deletingTrackIDs.remove(track.id)
                self.errorMessage = "Не удалось удалить песню: некорректный URL."
            }
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.deletingTrackIDs.remove(track.id)

                if let error = error {
                    self.errorMessage = "Не удалось удалить песню: \(error.localizedDescription)"
                    return
                }

                guard let data = data else {
                    self.errorMessage = "Не удалось удалить песню: пустой ответ."
                    return
                }

                do {
                    let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if response?["error"] != nil {
                        self.errorMessage = "VK отклонил удаление песни."
                        return
                    }
                    self.tracks.removeAll { $0.id == track.id && $0.ownerID == track.ownerID }
                } catch {
                    self.errorMessage = "Не удалось удалить песню: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func searchTracks(query: String, completion: @escaping (Result<[AudioTrack], VKRequestError>) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success([]))
            return
        }
        guard !accessToken.isEmpty else {
            completion(.failure(VKRequestError(message: "Нет токена доступа.")))
            return
        }

        var components = URLComponents(string: "https://api.vk.com/method/audio.search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "count", value: "50"),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "v", value: "5.131")
        ]

        guard let url = components?.url else {
            completion(.failure(VKRequestError(message: "Некорректный запрос поиска.")))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(VKRequestError(message: error.localizedDescription)))
                    return
                }
                guard let data = data else {
                    completion(.failure(VKRequestError(message: "Пустой ответ.")))
                    return
                }

                do {
                    if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let vkError = obj["error"] as? [String: Any],
                       let msg = vkError["error_msg"] as? String {
                        completion(.failure(VKRequestError(message: msg)))
                        return
                    }

                    let decoded = try JSONDecoder().decode(VKAudioSearchResponse.self, from: data)
                    completion(.success(decoded.response.items))
                } catch {
                    completion(.failure(VKRequestError(message: error.localizedDescription)))
                }
            }
        }.resume()
    }

    func addTrackToMyAudio(_ track: AudioTrack, completion: @escaping (Result<Void, VKRequestError>) -> Void) {
        guard !accessToken.isEmpty else {
            completion(.failure(VKRequestError(message: "Нет токена доступа.")))
            return
        }

        var components = URLComponents(string: "https://api.vk.com/method/audio.add")
        var queryItems = [
            URLQueryItem(name: "audio_id", value: String(track.id)),
            URLQueryItem(name: "owner_id", value: String(track.ownerID)),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "v", value: "5.131")
        ]
        if let accessKey = track.accessKey, !accessKey.isEmpty {
            queryItems.insert(URLQueryItem(name: "access_key", value: accessKey), at: 2)
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            completion(.failure(VKRequestError(message: "Некорректный URL.")))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(VKRequestError(message: error.localizedDescription)))
                    return
                }
                guard let data = data else {
                    completion(.failure(VKRequestError(message: "Пустой ответ.")))
                    return
                }

                do {
                    if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let vkError = obj["error"] as? [String: Any],
                       let msg = vkError["error_msg"] as? String {
                        completion(.failure(VKRequestError(message: msg)))
                        return
                    }
                    completion(.success(()))
                } catch {
                    completion(.failure(VKRequestError(message: error.localizedDescription)))
                }
            }
        }.resume()
    }
}

private func formatTrackDuration(_ seconds: Int?) -> String {
    let s = max(0, seconds ?? 0)
    let m = s / 60
    let sec = s % 60
    return String(format: "%02d:%02d", m, sec)
}

private func trackPlaylistKey(_ track: AudioTrack) -> String {
    "\(track.ownerID)_\(track.id)"
}

/// VK создаёт в библиотеке пользователя другую пару owner_id/audio_id после `audio.add`, поэтому
/// совпадение с плейлистом ищем по метаданным и длительности.
private func trackLibrarySimilarityKey(_ track: AudioTrack) -> String {
    let a = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let t = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(a)|\(t)|\(track.duration ?? 0)"
}

/// Где показывать блок с слайдером; воспроизведение при этом не останавливается.
enum NowPlayingChrome: Equatable {
    case hidden
    case mySongs
    case search
}

final class AudioPlayerStore: ObservableObject {
    @Published var nowPlayingChrome: NowPlayingChrome = .hidden
    @Published var selectedTrackID: Int?
    @Published var nowPlayingTrack: AudioTrack?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 1
    @Published var isDownloading = false
    @Published var downloadedTrackIDs: Set<Int> = []
    @Published var playerError: String?
    @Published var repeatOne = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var selectedTrack: AudioTrack?
    private var isSeeking = false
    private var itemStatusObserver: NSKeyValueObservation?
    private var playbackQueue: [AudioTrack] = []
    private var currentQueueIndex: Int = 0
    private var endPlaybackObserver: NSObjectProtocol?

    init() {
        setupAudioSession()
    }
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Ошибка настройки AVAudioSession: \(error)")
        }
    }

    deinit {
        removeEndObserver()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }

    private func removeEndObserver() {
        if let endPlaybackObserver {
            NotificationCenter.default.removeObserver(endPlaybackObserver)
        }
        endPlaybackObserver = nil
    }

    func resetForLogout() {
        pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        removeEndObserver()
        itemStatusObserver = nil
        player = nil
        selectedTrack = nil
        nowPlayingTrack = nil
        selectedTrackID = nil
        isPlaying = false
        currentTime = 0
        totalDuration = 1
        playerError = nil
        playbackQueue = []
        currentQueueIndex = 0
        repeatOne = false
        nowPlayingChrome = .hidden
    }

    /// Скрыть слайдер (например при открытии поиска или возврате с него); плеер не трогаем.
    func hidePlaybackChrome() {
        nowPlayingChrome = .hidden
    }

    func selectTrack(_ track: AudioTrack, playlist: [AudioTrack], chrome: NowPlayingChrome) {
        nowPlayingChrome = chrome
        guard let idx = playlist.firstIndex(where: { $0.id == track.id && $0.ownerID == track.ownerID }) else {
            playbackQueue = [track]
            currentQueueIndex = 0
            loadCurrentTrack(track)
            return
        }
        playbackQueue = playlist
        currentQueueIndex = idx
        loadAndPlayTrack(at: idx)
    }

    private func loadAndPlayTrack(at index: Int) {
        guard index >= 0 && index < playbackQueue.count else { return }
        loadCurrentTrack(playbackQueue[index])
    }

    private func loadCurrentTrack(_ track: AudioTrack) {
        guard let urlString = track.url, let url = URL(string: urlString) else {
            playerError = "Для этого трека нет URL воспроизведения."
            return
        }

        playerError = nil
        selectedTrackID = track.id
        nowPlayingTrack = track
        selectedTrack = track
        totalDuration = max(Double(track.duration ?? 1), 1)
        currentTime = 0

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemStatusObserver = nil
        removeEndObserver()

        let item = AVPlayerItem(url: url)
        itemStatusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if observedItem.status == .failed {
                    self.playerError = observedItem.error?.localizedDescription ?? "Не удалось начать воспроизведение."
                    self.isPlaying = false
                }
            }
        }
        player = AVPlayer(playerItem: item)
        addTimeObserver()

        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackReachedEnd()
        }

        play()
    }

    private func handlePlaybackReachedEnd() {
        if repeatOne {
            player?.seek(to: .zero)
            play()
            return
        }
        if currentQueueIndex + 1 < playbackQueue.count {
            currentQueueIndex += 1
            loadAndPlayTrack(at: currentQueueIndex)
        } else {
            pause()
            if let dur = player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                currentTime = dur
                totalDuration = dur
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func beginSeeking() {
        isSeeking = true
    }

    func endSeeking() {
        seek(to: currentTime)
        isSeeking = false
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func isTrackDownloaded(_ track: AudioTrack) -> Bool {
        downloadedTrackIDs.contains(track.id) || FileManager.default.fileExists(atPath: cacheURL(for: track).path)
    }

    func downloadSelectedTrackToCache() {
        guard let track = selectedTrack else { return }
        guard let urlString = track.url, let remoteURL = URL(string: urlString) else {
            playerError = "Невозможно скачать трек: отсутствует URL."
            return
        }

        let destinationURL = cacheURL(for: track)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            downloadedTrackIDs.insert(track.id)
            return
        }

        isDownloading = true
        playerError = nil

        URLSession.shared.downloadTask(with: remoteURL) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDownloading = false

                if let error = error {
                    self.playerError = "Ошибка скачивания: \(error.localizedDescription)"
                    return
                }

                guard let tempURL = tempURL else {
                    self.playerError = "Ошибка скачивания: временный файл не найден."
                    return
                }

                do {
                    let fm = FileManager.default
                    let cacheDirectory = self.trackCacheDirectory()
                    if !fm.fileExists(atPath: cacheDirectory.path) {
                        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                    }
                    try fm.moveItem(at: tempURL, to: destinationURL)
                    self.downloadedTrackIDs.insert(track.id)
                } catch {
                    self.playerError = "Ошибка сохранения в кэш: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if !self.isSeeking {
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
            if let itemDuration = self.player?.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                self.totalDuration = itemDuration
            }
        }
    }

    private func trackCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("track-cache")
    }

    private func cacheURL(for track: AudioTrack) -> URL {
        trackCacheDirectory().appendingPathComponent("\(track.ownerID)_\(track.id).mp3")
    }
}

private func formatPlaybackSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded())
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
}

private struct NowPlayingControlsView: View {
    @ObservedObject var playerStore: AudioPlayerStore
    var showDownloadToCache: Bool = true

    var body: some View {
        if playerStore.selectedTrackID != nil {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Slider(
                        value: $playerStore.currentTime,
                        in: 0...max(playerStore.totalDuration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                playerStore.beginSeeking()
                            } else {
                                playerStore.endSeeking()
                            }
                        }
                    )

                    Button {
                        playerStore.repeatOne.toggle()
                    } label: {
                        Image(systemName: "repeat.1")
                            .font(.title3)
                            .foregroundColor(playerStore.repeatOne ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        playerStore.repeatOne ? "Повтор одного трека включён. Нажмите, чтобы выключить." : "Повтор одного трека выключен. Нажмите, чтобы включить."
                    )
                }

                HStack {
                    Text(formatPlaybackSeconds(playerStore.currentTime))
                    Spacer()
                    Text(formatPlaybackSeconds(playerStore.totalDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button(action: {
                        playerStore.togglePlayPause()
                    }) {
                        Image(systemName: playerStore.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)

                    if showDownloadToCache {
                        Button(action: {
                            playerStore.downloadSelectedTrackToCache()
                        }) {
                            if playerStore.isDownloading {
                                ProgressView()
                            } else {
                                Text("Скачать в кэш")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
    }
}

private struct SearchTracksView: View {
    @ObservedObject var authStore: VKAuthStore
    @ObservedObject var playerStore: AudioPlayerStore

    @State private var query = ""
    @State private var results: [AudioTrack] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var addingKeys: Set<String> = []

    private var keysInLibrary: Set<String> {
        Set(authStore.tracks.map(trackLibrarySimilarityKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            if playerStore.nowPlayingChrome == .search {
                NowPlayingControlsView(playerStore: playerStore, showDownloadToCache: false)
            }

            Group {
                if isSearching {
                    ProgressView("Ищем…")
                        .frame(maxHeight: .infinity)
                } else if let searchError {
                    ScrollView {
                        Text(searchError)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else if results.isEmpty {
                    Spacer(minLength: 0)
                    Text("Введите запрос и нажмите кнопку поиска справа.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer(minLength: 0)
                } else {
                    List(results, id: \.self) { track in
                        searchRow(for: track)
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let playerError = playerStore.playerError {
                Text(playerError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
        }
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                TextField("Поиск в VK", text: $query)
                    .textFieldStyle(.roundedBorder)
#if os(iOS)
                    .submitLabel(.search)
#endif
                    .onSubmit {
                        runSearch()
                    }

                Button(action: runSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundColor(Color.accentColor)
                }
                .disabled(trimmedQuery.isEmpty || isSearching)
                .accessibilityLabel("Искать")
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
        .onAppear {
            playerStore.hidePlaybackChrome()
        }
        .onDisappear {
            playerStore.hidePlaybackChrome()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchRow(for track: AudioTrack) -> some View {
        let dedupeKey = trackLibrarySimilarityKey(track)
        let isMine = keysInLibrary.contains(dedupeKey)
        let addKey = trackPlaylistKey(track)
        let isAdding = addingKeys.contains(addKey)

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Text(formatTrackDuration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)

            if isMine {
                Image(systemName: "flag.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Уже в плейлисте")
            }

            if !isMine {
                Button {
                    addToPlaylist(track)
                } label: {
                    if isAdding {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Добавить в плейлист")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playerStore.selectTrack(track, playlist: results, chrome: .search)
        }
    }

    private func runSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        searchError = nil
        isSearching = true
        authStore.searchTracks(query: q) { result in
            isSearching = false
            switch result {
            case .success(let items):
                results = items
            case .failure(let err):
                searchError = err.localizedDescription
                results = []
            }
        }
    }

    private func addToPlaylist(_ track: AudioTrack) {
        let key = trackPlaylistKey(track)
        guard !addingKeys.contains(key) else { return }
        addingKeys.insert(key)
        authStore.addTrackToMyAudio(track) { result in
            addingKeys.remove(key)
            switch result {
            case .success:
                authStore.fetchTracks()
            case .failure(let err):
                searchError = err.localizedDescription
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var authStore = VKAuthStore()
    @StateObject private var playerStore = AudioPlayerStore()
    @State private var isAuthWebViewPresented = false

    var body: some View {
        NavigationView {
            switch authStore.screen {
            case .auth:
                authView
                    .navigationTitle("Авторизация")
            case .songs:
                songsView
                    .navigationTitle("Мои песни")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            NavigationLink(destination: SearchTracksView(authStore: authStore, playerStore: playerStore)) {
                                Image(systemName: "magnifyingglass")
                            }
                            .accessibilityLabel("Поиск")
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Выйти") {
                                authStore.logout()
                                playerStore.resetForLogout()
                            }
                            .accessibilityLabel("Выйти из аккаунта")
                        }
                    }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            if !authStore.accessToken.isEmpty && authStore.tracks.isEmpty {
                authStore.fetchTracks()
            }
        }
    }

    private var authView: some View {
        VStack(spacing: 18) {
            Spacer()
            Button("Авторизоваться в VK") {
                isAuthWebViewPresented = true
            }
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isAuthWebViewPresented) {
            VKAuthWebView(
                onSuccess: { token in
                    authStore.saveToken(token)
                    isAuthWebViewPresented = false
                },
                onFailure: { error in
                    authStore.errorMessage = error.localizedDescription
                    isAuthWebViewPresented = false
                }
            )
        }
    }

    private var songsView: some View {
        VStack(spacing: 0) {
            if playerStore.nowPlayingChrome == .mySongs {
                NowPlayingControlsView(playerStore: playerStore)
            }

            if authStore.isLoading {
                ProgressView("Загружаем песни...")
            } else if let error = authStore.errorMessage {
                VStack(spacing: 16) {
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Повторить") {
                        authStore.fetchTracks()
                    }
                }
            } else if authStore.tracks.isEmpty {
                Text("Список песен пуст.")
            } else {
                List(authStore.tracks) { track in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.headline)
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(formatTrackDuration(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        if playerStore.isTrackDownloaded(track) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                        }
                        Button(role: .destructive) {
                            authStore.deleteTrack(track)
                        } label: {
                            if authStore.deletingTrackIDs.contains(track.id) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Image(systemName: "trash")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playerStore.selectTrack(track, playlist: authStore.tracks, chrome: .mySongs)
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }

            if let playerError = playerStore.playerError {
                Text(playerError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct VKAuthWebView: UIViewRepresentable {
    let onSuccess: (String) -> Void
    let onFailure: (Error) -> Void

    private let callbackScheme = "vkmusicauth"
    private var redirectURI: String {
        "\(callbackScheme)://oauth.vk.com/blank.html"
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        guard let authURL = makeAuthURL() else {
            onFailure(VKAuthError.invalidAuthURL)
            return webView
        }

        webView.load(URLRequest(url: authURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func makeAuthURL() -> URL? {
        var components = URLComponents(string: "https://oauth.vk.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: "6463690"),
            URLQueryItem(name: "display", value: "mobile"),
            URLQueryItem(name: "scope", value: "audio,offline"),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "v", value: "5.131")
        ]
        return components?.url
    }

    private func extractToken(from callbackURL: URL) -> String? {
        if let tokenFromFragment = tokenValue(in: callbackURL.fragment) {
            return tokenFromFragment
        }

        return tokenValue(in: callbackURL.query)
    }

    private func tokenValue(in parameterString: String?) -> String? {
        guard let parameterString else {
            return nil
        }

        for parameter in parameterString.split(separator: "&") {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 && pair[0] == "access_token" {
                return pair[1].removingPercentEncoding ?? pair[1]
            }
        }

        return nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: VKAuthWebView

        init(parent: VKAuthWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Проверяем, что мы попали на страницу редиректа VK
            if url.host == "oauth.vk.com" && url.path == "/blank.html" {
                // Извлекаем токен из фрагмента (#) или query (?)
                if let token = parent.extractToken(from: url) {
                    parent.onSuccess(token)
                    decisionHandler(.cancel) // Останавливаем загрузку, так как токен получен
                    return
                }
            }

            decisionHandler(.allow)
        }
    }
}

enum VKAuthError: LocalizedError {
    case invalidAuthURL
    case emptyCallback
    case tokenNotFound
    case unableToStartSession

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:
            return "Не удалось сформировать URL авторизации VK."
        case .emptyCallback:
            return "Не получен callback URL после авторизации."
        case .tokenNotFound:
            return "Токен не найден в callback URL."
        case .unableToStartSession:
            return "Не удалось запустить сессию авторизации."
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
