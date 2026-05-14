import SwiftUI
import UIKit
import WebKit
import AVFoundation
import MediaPlayer

struct AudioTrack: Codable, Identifiable, Hashable {
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
    let count: Int?
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
    private let tracksStorageKey = "vk_tracks_cache"
    /// Максимум записей за один вызов `audio.get` по документации VK.
    private let audioGetPageSize = 6000

    @Published var accessToken: String = ""
    @Published var tracks: [AudioTrack] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var deletingTrackIDs: Set<Int> = []

    init() {
        accessToken = UserDefaults.standard.string(forKey: tokenStorageKey) ?? ""
        tracks = loadCachedTracks()
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
        UserDefaults.standard.removeObject(forKey: tracksStorageKey)
        tracks = []
        errorMessage = nil
    }

    func fetchTracks() {
        guard !accessToken.isEmpty else {
            return
        }

        isLoading = true

        fetchTracksPage(offset: 0, accumulated: []) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let allTracks):
                    self.tracks = allTracks
                    self.cacheTracks(allTracks)
                    self.errorMessage = nil
                case .failure(let err):
                    self.errorMessage = err.message
                }
            }
        }
    }

    /// Подгружает все страницы «Мои аудио» (`audio.get` с offset/count), иначе VK отдаёт только первую порцию.
    private func fetchTracksPage(offset: Int, accumulated: [AudioTrack], completion: @escaping (Result<[AudioTrack], VKRequestError>) -> Void) {
        guard !accessToken.isEmpty else {
            completion(.success(accumulated))
            return
        }

        var components = URLComponents(string: "https://api.vk.com/method/audio.get")
        components?.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "count", value: String(audioGetPageSize)),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "v", value: "5.131")
        ]

        guard let url = components?.url else {
            completion(.failure(VKRequestError(message: "Некорректный URL для запроса аудио.")))
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else {
                completion(.failure(VKRequestError(message: "Не удалось обновить список песен. Показаны сохранённые треки.")))
                return
            }

            if let error = error {
                completion(.failure(VKRequestError(message: "Не удалось обновить список песен: \(error.localizedDescription). Показаны сохранённые треки.")))
                return
            }

            guard let data = data else {
                completion(.failure(VKRequestError(message: "Не удалось обновить список песен: пустой ответ. Показаны сохранённые треки.")))
                return
            }

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let vkError = obj["error"] as? [String: Any],
               let msg = vkError["error_msg"] as? String {
                completion(.failure(VKRequestError(message: "VK: \(msg). Показаны сохранённые треки.")))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(VKAudioResponse.self, from: data)
                let page = decoded.response.items
                let merged = accumulated + page
                if page.count == self.audioGetPageSize {
                    self.fetchTracksPage(offset: offset + page.count, accumulated: merged, completion: completion)
                } else {
                    completion(.success(merged))
                }
            } catch {
                completion(.failure(VKRequestError(message: "Не удалось обновить список песен: \(error.localizedDescription). Показаны сохранённые треки.")))
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
                    self.cacheTracks(self.tracks)
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

    private func loadCachedTracks() -> [AudioTrack] {
        guard let data = UserDefaults.standard.data(forKey: tracksStorageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([AudioTrack].self, from: data)) ?? []
    }

    private func cacheTracks(_ tracks: [AudioTrack]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: tracksStorageKey)
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

    /// Очередь даёт переход на следующий трек внутри AVFoundation (в т.ч. в фоне), без ожидания main run loop.
    private var queuePlayer: AVQueuePlayer?
    private var timeObserver: Any?
    private var selectedTrack: AudioTrack?
    private var isSeeking = false
    private var playbackQueue: [AudioTrack] = []
    private var currentQueueIndex: Int = 0

    private var itemTrackIndex: [ObjectIdentifier: Int] = [:]
    private var itemEndObservers: [NSObjectProtocol] = []
    private var itemStatusObservations: [NSKeyValueObservation] = []
    private var currentItemObserver: NSKeyValueObservation?

    /// Для повтора одного трека и финала плейлиста — обновление UI/seek на main после остановки.
    private var advanceTrackBackgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        setupAudioSession()
        configureRemoteTransportControls()
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
        releasePlayerResources()
    }

    private func beginAdvanceTrackBackgroundTask() {
        endAdvanceTrackBackgroundTask()
        advanceTrackBackgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endAdvanceTrackBackgroundTask()
        }
    }

    private func endAdvanceTrackBackgroundTask() {
        guard advanceTrackBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(advanceTrackBackgroundTask)
        advanceTrackBackgroundTask = .invalid
    }

    private func removeAllItemEndObservers() {
        for observer in itemEndObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemEndObservers.removeAll()
    }

    private func clearItemStatusObservations() {
        itemStatusObservations.removeAll()
    }

    private func releasePlayerResources() {
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        removeAllItemEndObservers()
        clearItemStatusObservations()
        if let observer = timeObserver {
            queuePlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
        endAdvanceTrackBackgroundTask()
        queuePlayer?.pause()
        queuePlayer = nil
        itemTrackIndex.removeAll()
        clearNowPlaying()
    }

    func resetForLogout() {
        releasePlayerResources()
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
            loadAndPlayTrack(at: 0)
            return
        }
        playbackQueue = playlist
        loadAndPlayTrack(at: idx)
    }

    private func loadAndPlayTrack(at index: Int) {
        guard index >= 0 && index < playbackQueue.count else { return }
        loadCurrentTrack(at: index)
    }

    private func makePlayerItem(for track: AudioTrack) -> AVPlayerItem? {
        let localURL = cacheURL(for: track)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return AVPlayerItem(url: localURL)
        }
        guard let urlString = track.url, let url = URL(string: urlString) else { return nil }
        return AVPlayerItem(url: url)
    }

    private func observeItemFailure(_ item: AVPlayerItem) {
        let observation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if observedItem.status == .failed {
                    self.playerError = observedItem.error?.localizedDescription ?? "Не удалось начать воспроизведение."
                    self.isPlaying = false
                    self.clearNowPlaying()
                }
            }
        }
        itemStatusObservations.append(observation)
    }

    private func attachPlayToEndObserver(_ item: AVPlayerItem, trackIndex: Int) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            self?.handleItemPlayedToEnd(trackIndex: trackIndex)
        }
        itemEndObservers.append(observer)
    }

    private func handleItemPlayedToEnd(trackIndex: Int) {
        if repeatOne {
            beginAdvanceTrackBackgroundTask()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let qp = self.queuePlayer else {
                    self.endAdvanceTrackBackgroundTask()
                    return
                }
                qp.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    DispatchQueue.main.async { [weak self] in
                        defer { self?.endAdvanceTrackBackgroundTask() }
                        guard let self, finished else { return }
                        self.queuePlayer?.play()
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                    }
                }
            }
            return
        }
        guard trackIndex == playbackQueue.count - 1 else { return }
        beginAdvanceTrackBackgroundTask()
        DispatchQueue.main.async { [weak self] in
            defer { self?.endAdvanceTrackBackgroundTask() }
            guard let self else { return }
            self.pause()
            if let dur = self.queuePlayer?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                self.currentTime = dur
                self.totalDuration = dur
            }
            self.updateNowPlayingInfo()
        }
    }

    private func observeCurrentItem(on player: AVQueuePlayer) {
        currentItemObserver?.invalidate()
        currentItemObserver = player.observe(\.currentItem, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.syncPublishedStateToCurrentItem()
            }
        }
    }

    private func syncPublishedStateToCurrentItem() {
        guard let item = queuePlayer?.currentItem,
              let idx = itemTrackIndex[ObjectIdentifier(item)] else { return }
        let trackChanged = currentQueueIndex != idx
        currentQueueIndex = idx
        let track = playbackQueue[idx]
        selectedTrackID = track.id
        nowPlayingTrack = track
        selectedTrack = track
        totalDuration = max(Double(track.duration ?? 1), 1)
        if trackChanged {
            currentTime = 0
        }
        topUpForwardBuffer()
        updateNowPlayingInfo()
    }

    /// Держим в очереди текущий и следующий трек (следующий стартует без участия main).
    private func topUpForwardBuffer() {
        guard let qp = queuePlayer, !repeatOne else { return }
        while qp.items().count < 2 {
            guard let lastItem = qp.items().last,
                  let lastIdx = itemTrackIndex[ObjectIdentifier(lastItem)] else { return }
            let nextIdx = lastIdx + 1
            guard nextIdx < playbackQueue.count else { return }
            guard let nextItem = makePlayerItem(for: playbackQueue[nextIdx]) else { return }
            observeItemFailure(nextItem)
            itemTrackIndex[ObjectIdentifier(nextItem)] = nextIdx
            attachPlayToEndObserver(nextItem, trackIndex: nextIdx)
            qp.insert(nextItem, after: lastItem)
        }
    }

    private func loadCurrentTrack(at index: Int) {
        guard index >= 0 && index < playbackQueue.count else { return }
        let track = playbackQueue[index]
        guard makePlayerItem(for: track) != nil else {
            playerError = "Для этого трека нет URL воспроизведения."
            return
        }

        playerError = nil
        releasePlayerResources()

        var items: [AVPlayerItem] = []
        guard let firstItem = makePlayerItem(for: track) else {
            playerError = "Для этого трека нет URL воспроизведения."
            return
        }
        observeItemFailure(firstItem)
        itemTrackIndex[ObjectIdentifier(firstItem)] = index
        attachPlayToEndObserver(firstItem, trackIndex: index)
        items.append(firstItem)

        if !repeatOne, index + 1 < playbackQueue.count, let secondItem = makePlayerItem(for: playbackQueue[index + 1]) {
            let nextIndex = index + 1
            observeItemFailure(secondItem)
            itemTrackIndex[ObjectIdentifier(secondItem)] = nextIndex
            attachPlayToEndObserver(secondItem, trackIndex: nextIndex)
            items.append(secondItem)
        }

        let qp = AVQueuePlayer(items: items)
        queuePlayer = qp
        observeCurrentItem(on: qp)
        addTimeObserver()

        currentQueueIndex = index
        selectedTrackID = track.id
        nowPlayingTrack = track
        selectedTrack = track
        totalDuration = max(Double(track.duration ?? 1), 1)
        currentTime = 0

        topUpForwardBuffer()
        play()
    }

    /// Включение «повтор одного» убирает предзагруженный следующий трек, иначе очередь переключилась бы на него раньше обработчика повтора.
    func toggleRepeatOne() {
        repeatOne.toggle()
        if repeatOne {
            trimQueuedItemsAfterCurrent()
        } else {
            topUpForwardBuffer()
        }
        updateNowPlayingInfo()
    }

    private func trimQueuedItemsAfterCurrent() {
        guard let qp = queuePlayer, let currentItem = qp.currentItem else { return }
        let toRemove = qp.items().filter { $0 !== currentItem }
        removeAllItemEndObservers()
        for item in toRemove {
            qp.remove(item)
            itemTrackIndex.removeValue(forKey: ObjectIdentifier(item))
        }
        guard let idx = itemTrackIndex[ObjectIdentifier(currentItem)] else { return }
        attachPlayToEndObserver(currentItem, trackIndex: idx)
    }

    private func configureRemoteTransportControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.play()
            }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.pause()
            }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.togglePlayPause()
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async {
                self.seek(to: e.positionTime)
            }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.skipToNextTrack()
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.skipToPreviousTrack()
            }
            return .success
        }
    }

    private func clearNowPlaying() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.clearNowPlaying() }
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateNowPlayingInfo() }
            return
        }
        guard let track = nowPlayingTrack else {
            clearNowPlaying()
            return
        }
        let durationSeconds: Double = {
            if totalDuration.isFinite, totalDuration > 0 { return totalDuration }
            let d = Double(track.duration ?? 0)
            return d > 0 ? d : 1
        }()
        let elapsed = min(max(0, currentTime), durationSeconds)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let commands = MPRemoteCommandCenter.shared()
        let canNext = !repeatOne && currentQueueIndex + 1 < playbackQueue.count
        commands.nextTrackCommand.isEnabled = canNext
        commands.previousTrackCommand.isEnabled = true
    }

    private func skipToNextTrack() {
        guard !repeatOne else { return }
        let next = currentQueueIndex + 1
        guard next < playbackQueue.count else { return }
        loadCurrentTrack(at: next)
    }

    private func skipToPreviousTrack() {
        guard !playbackQueue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentQueueIndex > 0 {
            loadCurrentTrack(at: currentQueueIndex - 1)
        } else {
            seek(to: 0)
        }
    }

    func play() {
        queuePlayer?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        queuePlayer?.pause()
        isPlaying = false
        updateNowPlayingInfo()
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
        guard let player = queuePlayer else { return }
        let durationSeconds: Double = {
            if totalDuration.isFinite, totalDuration > 0 { return totalDuration }
            if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
            return 1
        }()
        let clamped = min(max(0, seconds), durationSeconds)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished else { return }
            DispatchQueue.main.async {
                self.currentTime = clamped
                self.updateNowPlayingInfo()
            }
        }
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
        timeObserver = queuePlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if !self.isSeeking {
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
            if let itemDuration = self.queuePlayer?.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                self.totalDuration = itemDuration
            }
            self.updateNowPlayingInfo()
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
                if let track = playerStore.nowPlayingTrack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
                        playerStore.toggleRepeatOne()
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
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var authStore = VKAuthStore()
    @StateObject private var playerStore = AudioPlayerStore()
    @State private var isAuthWebViewPresented = false
    @State private var isNowPlayingControlsHidden = false

    var body: some View {
        NavigationView {
            switch authStore.screen {
            case .auth:
                authView
                    .navigationTitle("Авторизация")
            case .songs:
                songsView
                    .navigationTitle("Музыка VK")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                isNowPlayingControlsHidden.toggle()
                            } label: {
                                Image(systemName: isNowPlayingControlsHidden ? "eye" : "eye.slash")
                            }
                            .accessibilityLabel(
                                isNowPlayingControlsHidden
                                    ? "Показать панель плеера"
                                    : "Скрыть панель плеера"
                            )
                        }
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
            if playerStore.nowPlayingChrome == .mySongs && !isNowPlayingControlsHidden {
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
                ScrollViewReader { proxy in
                    List(authStore.tracks) { track in
                        let playing = isNowPlayingTrack(track)
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
                        .listRowBackground(
                            playing
                                ? Color.accentColor.opacity(0.12)
                                : nil
                        )
                        .id(mySongsRowId(track))
                    }
                    .listStyle(InsetGroupedListStyle())
                    .onChange(of: scenePhase) { phase in
                        if phase == .active {
                            scrollNowPlayingRowIntoView(using: proxy)
                        }
                    }
                }
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

    private func mySongsRowId(_ track: AudioTrack) -> String {
        "my_songs_\(track.ownerID)_\(track.id)"
    }

    private func isNowPlayingTrack(_ track: AudioTrack) -> Bool {
        guard let np = playerStore.nowPlayingTrack else { return false }
        return np.id == track.id && np.ownerID == track.ownerID
    }

    private func scrollNowPlayingRowIntoView(using proxy: ScrollViewProxy) {
        guard let np = playerStore.nowPlayingTrack else { return }
        guard authStore.tracks.contains(where: { $0.id == np.id && $0.ownerID == np.ownerID }) else {
            return
        }
        let targetId = mySongsRowId(np)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .center)
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
