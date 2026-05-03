import SwiftUI
import AuthenticationServices

struct AudioTrack: Decodable, Identifiable {
    let id: Int
    let artist: String
    let title: String
    let duration: Int?
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
}

struct ContentView: View {
    @StateObject private var authStore = VKAuthStore()
    @StateObject private var authSessionManager = VKAuthSessionManager()

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
        VStack {
            Spacer()
            Button("Авторизоваться в VK") {
                authSessionManager.start { result in
                    switch result {
                    case .success(let token):
                        authStore.saveToken(token)
                    case .failure(let error):
                        authStore.errorMessage = error.localizedDescription
                    }
                }
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
    }

    private var songsView: some View {
        Group {
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.headline)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
        }
    }
}

final class VKAuthSessionManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private let callbackScheme = "vkmusicauth"
    private lazy var redirectURI = "\(callbackScheme)://oauth.vk.com/blank.html"
    private var currentSession: ASWebAuthenticationSession?

    func start(onResult: @escaping (Result<String, Error>) -> Void) {
        guard let authURL = makeAuthURL() else {
            onResult(.failure(VKAuthError.invalidAuthURL))
            return
        }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            self?.currentSession = nil

            if let error = error {
                onResult(.failure(error))
                return
            }

            guard let callbackURL = callbackURL else {
                onResult(.failure(VKAuthError.emptyCallback))
                return
            }

            guard let token = self?.extractToken(from: callbackURL) else {
                onResult(.failure(VKAuthError.tokenNotFound))
                return
            }

            onResult(.success(token))
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        currentSession = session

        if !session.start() {
            onResult(.failure(VKAuthError.unableToStartSession))
            currentSession = nil
        }
    }

    private func makeAuthURL() -> URL? {
        var components = URLComponents(string: "https://oauth.vk.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: "6463690"),
            URLQueryItem(name: "display", value: "page"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "audio,offline"),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "v", value: "5.131"),
        ]
        return components?.url
    }

    private func extractToken(from callbackURL: URL) -> String? {
        guard let fragment = callbackURL.fragment else {
            return nil
        }

        let params = fragment.split(separator: "&")
        for param in params {
            let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 && pair[0] == "access_token" {
                return pair[1]
            }
        }
        return nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
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
