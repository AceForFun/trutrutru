import SwiftUI
import WebKit
import AVFoundation

struct AudioTrack: Decodable, Identifiable {
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

    func saveTokenFromURLString(_ urlString: String) {
        guard let token = extractToken(from: urlString) else {
            errorMessage = "Не удалось найти access_token в URL."
            return
        }
        saveToken(token)
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

    private func extractToken(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        // Supports both full OAuth callback URL and plain token text.
        if !trimmed.contains("://") && !trimmed.contains("#") && !trimmed.contains("&") {
            return trimmed
        }

        let fragmentString: String?
        if let hashIndex = trimmed.firstIndex(of: "#") {
            fragmentString = String(trimmed[trimmed.index(after: hashIndex)...])
        } else {
            fragmentString = URLComponents(string: trimmed)?.fragment
        }

        guard let fragment = fragmentString else {
            return nil
        }

        for param in fragment.split(separator: "&") {
            let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 && pair[0] == "access_token" {
                return pair[1]
            }
        }

        return nil
    }
}

final class AudioPlayerStore: ObservableObject {
    @Published var selectedTrackID: Int?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 1
    @Published var isDownloading = false
    @Published var downloadedTrackIDs: Set<Int> = []
    @Published var playerError: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var selectedTrack: AudioTrack?
    private var isSeeking = false
    private var itemStatusObserver: NSKeyValueObservation?

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
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }

    func selectTrack(_ track: AudioTrack) {
        guard let urlString = track.url, let url = URL(string: urlString) else {
            playerError = "Для этого трека нет URL воспроизведения."
            return
        }

        playerError = nil
        selectedTrackID = track.id
        selectedTrack = track
        totalDuration = max(Double(track.duration ?? 1), 1)
        currentTime = 0

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemStatusObserver = nil

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
        play()
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

struct ContentView: View {
    @StateObject private var authStore = VKAuthStore()
    @StateObject private var playerStore = AudioPlayerStore()
    @State private var isAuthWebViewPresented = false
    @State private var isManualTokenURLInputVisible = false
    @State private var manualTokenURL = ""

    var body: some View {
        NavigationView {
            Group {
                switch authStore.screen {
                case .auth:
                    authView
                case .songs:
                    songsView
                }
            }
            .navigationTitle(authStore.screen == .auth ? "Авторизация" : "Мои песни")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Group {
                        if authStore.screen == .songs {
                            Button(action: { authStore.logout() }) {
                                Image(systemName: "square.and.arrow.right")
                            }
                            .accessibilityLabel("Выйти")
                        }
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

            Button(isManualTokenURLInputVisible ? "Скрыть ввод URL с токеном" : "Ставить URL с токеном") {
                withAnimation {
                    isManualTokenURLInputVisible.toggle()
                }
            }
            .font(Font.system(size: 15))

            if isManualTokenURLInputVisible {
                VStack(spacing: 10) {
                    TextField("Введите URL с токеном", text: $manualTokenURL)
                        .padding(.horizontal, 24)

                    Button("Загрузить песни по URL") {
                        authStore.saveTokenFromURLString(manualTokenURL)
                    }
                    .disabled(manualTokenURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
            if playerStore.selectedTrackID != nil {
                VStack(spacing: 12) {
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

                    HStack(spacing: 16) {
                        Button(action: {
                            playerStore.togglePlayPause()
                        }) {
                            Image(systemName: playerStore.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderedProminent)

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
                .padding()
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
                        Spacer()
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
                        playerStore.selectTrack(track)
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
