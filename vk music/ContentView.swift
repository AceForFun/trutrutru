import SwiftUI
import WebKit

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

struct ContentView: View {
    @StateObject private var authStore = VKAuthStore()
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
