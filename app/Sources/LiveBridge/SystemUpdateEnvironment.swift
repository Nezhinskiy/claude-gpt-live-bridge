import BridgeCore
import Darwin
import Foundation

/// The `UpdateEnvironment` the app runs on: GitHub over the network, the programs on this Mac,
/// the swap in `/Applications` and the relaunch (the spec's "How an update runs").
final class SystemUpdateEnvironment: UpdateEnvironment {
  /// The largest release-check reply read.
  static let replyLimit = 2 * 1024 * 1024
  /// The programs whose output includes their standard error: `codesign -dvvv` prints its
  /// `CDHash=` line there. Every other program gives only its standard output, so a warning on
  /// standard error cannot spoil the JSON or property list the `Updater` reads from it.
  static let reportingOnStandardError: Set<String> = ["/usr/bin/codesign"]

  /// GitHub's `releases/latest` for this repository, or a debug build's stand-in.
  private let releasesURL: URL
  private let searchPath = SearchPath()

  init(releasesURL: URL) {
    self.releasesURL = releasesURL
  }

  func fetchLatest() async throws(UpdateProblem) -> Data {
    var request = URLRequest(url: releasesURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    do throws(UpdateProblem) {
      return try await Transfer.run(
        request, hosts: DownloadRules.apiHosts, maxBytes: Self.replyLimit, into: nil)
    } catch .tooLarge {
      throw .network("GitHub's reply was larger than a release.")
    }
  }

  func download(_ url: URL, to file: URL, maxBytes: Int) async throws(UpdateProblem) {
    guard DownloadRules.allowsRedirect(to: url, hosts: DownloadRules.assetHosts) else {
      throw .network("The update image is not on GitHub.")
    }
    guard FileManager.default.createFile(atPath: file.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: file)
    else { throw .network("The update image could not be saved.") }
    defer { try? handle.close() }
    do throws(UpdateProblem) {
      _ = try await Transfer.run(
        URLRequest(url: url), hosts: DownloadRules.assetHosts, maxBytes: maxBytes, into: handle)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  func locate(_ program: String) async -> URL? {
    CodexLaunch.locate(program, searchPath: await searchPath.value())
  }

  func run(_ executable: URL, _ arguments: [String], cwd: URL?, timeout: Duration) async
    -> ProgramResult?
  {
    let answer = try? await CodexLaunch.run(
      executable, arguments, searchPath: await searchPath.value(), cwd: cwd,
      mergingErrors: Self.reportingOnStandardError.contains(executable.path), timeout: timeout)
    return answer.map { ProgramResult(status: $0.status, output: $0.output) }
  }

  func swap(_ a: URL, _ b: URL) throws {
    guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
      throw UpdateProblem.swapFailed(String(cString: strerror(errno)))
    }
  }

  func relaunch(pid: Int32, app: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = RelaunchScript.arguments(pid: pid, app: app.path)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  func osVersion() -> OperatingSystemVersion {
    ProcessInfo.processInfo.operatingSystemVersion
  }

  func sleep(for duration: Duration) async {
    try? await Task.sleep(for: duration)
  }
}

/// `CodexLaunch.defaultSearchPath()`, asked once (it starts the owner's shell) and only when
/// first needed; `gh` and `claude` are found on it and every program runs with it as `PATH`.
private actor SearchPath {
  private var answer: Task<[String], Never>?

  func value() async -> [String] {
    let answer = self.answer ?? Task { await CodexLaunch.defaultSearchPath() }
    self.answer = answer
    return await answer.value
  }
}

/// One request on its own ephemeral session, with no cookies, cache or stored credentials. It
/// follows a redirect only as `DownloadRules` allows, refuses a non-2xx status, and is cut off
/// once the length it declares or the bytes it delivers pass `maxBytes`. The body goes to
/// `file`, or is returned when there is none. The session calls back on one serial queue; the
/// lock covers the hand-over of the continuation from the caller.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let hosts: Set<String>
  private let maxBytes: Int
  private let file: FileHandle?
  private let lock = NSLock()
  private var body = Data()
  private var received: Int64 = 0
  private var problem: UpdateProblem?
  private var continuation: CheckedContinuation<Result<Data, UpdateProblem>, Never>?

  private init(hosts: Set<String>, maxBytes: Int, file: FileHandle?) {
    self.hosts = hosts
    self.maxBytes = maxBytes
    self.file = file
  }

  static func run(
    _ request: URLRequest, hosts: Set<String>, maxBytes: Int, into file: FileHandle?
  ) async throws(UpdateProblem) -> Data {
    let transfer = Transfer(hosts: hosts, maxBytes: maxBytes, file: file)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 15 * 60
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(
      configuration: configuration, delegate: transfer, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        transfer.locked { transfer.continuation = continuation }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
    return try result.get()
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  /// Ends the transfer with `problem` (the first one stands).
  private func fail(_ problem: UpdateProblem, _ task: URLSessionTask) {
    locked { if self.problem == nil { self.problem = problem } }
    task.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url, DownloadRules.allowsRedirect(to: url, hosts: hosts) else {
      fail(.network("GitHub redirected the request away from its own hosts."), task)
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      fail(.http(http.statusCode), dataTask)
      completionHandler(.cancel)
    } else if DownloadRules.exceeds(
      maxBytes: maxBytes, declared: response.expectedContentLength, received: 0)
    {
      fail(.tooLarge, dataTask)
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let refused: UpdateProblem? = locked {
      guard problem == nil else { return nil }
      received += Int64(data.count)
      if DownloadRules.exceeds(maxBytes: maxBytes, declared: -1, received: received) {
        return .tooLarge
      }
      guard let file else {
        body.append(data)
        return nil
      }
      do {
        try file.write(contentsOf: data)
        return nil
      } catch {
        return .network("The update image could not be saved.")
      }
    }
    if let refused { fail(refused, dataTask) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let (continuation, result) = locked {
      let result: Result<Data, UpdateProblem> =
        if let problem { .failure(problem) } else if let error {
          .failure(.network(error.localizedDescription))
        } else { .success(body) }
      defer { self.continuation = nil }
      return (self.continuation, result)
    }
    continuation?.resume(returning: result)
  }
}
