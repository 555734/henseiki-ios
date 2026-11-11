import Foundation
import VoiceCloneCore

/// Downloads with a background URL session, so the transfer continues when the app is closed or the screen is off.
/// No account or cookies are used. A partial download is resumed instead of started again.
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloader()
    static let identifier = "com.voiceclone.app.modeldownload"

    /// Set by the app delegate when iOS wakes the app to deliver finished transfers.
    var backgroundCompletion: (() -> Void)?
    private var progress: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var moveError: Error?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: BackgroundDownloader.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Downloads [url] to [destination]. Re-attaches to a transfer that is already running (for example after the app was relaunched).
    func download(from url: URL, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard url.scheme == "https" else { throw EngineError.message("暗号化されていない配布先には接続しません") }
        self.progress = progress
        self.destination = destination
        self.moveError = nil
        let existing = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }.first { $0.originalRequest?.url == url }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let task = existing ?? session.downloadTask(with: URLRequest(url: url))
            task.resume()
        }
    }

    func cancel() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = EngineError.message(http.statusCode == 404 ? "このモデルは公開配布の準備中です。時間をおいて、もう一度お試しください。" : "モデルの取得に失敗しました（HTTP \(http.statusCode)）")
            return
        }
        guard let destination else { return }
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? EngineError.cancelled : error) }
        else if let moveError { continuation?.resume(throwing: moveError) }
        else { continuation?.resume() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }
}

/// Small plain requests (the distribution catalog) without cookies or credentials.
enum PublicFetch {
    static func data(from url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw EngineError.message("暗号化されていない配布先には接続しません") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EngineError.message(http.statusCode == 404 ? "このモデルは公開配布の準備中です。時間をおいて、もう一度お試しください。" : "モデル配布先に接続できません（HTTP \(http.statusCode)）")
        }
        return data
    }
}
