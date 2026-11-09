import AppKit
import CryptoKit
import PaveCore
import Security

/// Pavé's own updates: the releases of a GitHub repository (`[updates]
/// source`), read from GitHub's public API (no account, no token), or with
/// `gh` and the user's own access when the repository is private.
///
/// Only a copy signed with the certificate of the releases
/// (`Contents/Resources/update-cert.sha256`) looks for updates: one built
/// from source and signed with another certificate could not install them.
///
/// Installing downloads `Pave_<version>.app.tar.gz` and its `.minisig`, and
/// installs only if:
/// - the signature is from the key built into this Pavé
///   (`Contents/Resources/update-key.pub`) and names that very file;
/// - the new app's code signature satisfies this app's designated
///   requirement (the same "Pave Dev" certificate, the same identifier):
///   what keeps the Accessibility permission, and refuses any other app.
/// The app is then replaced where it runs and Pavé restarts, as with
/// `just install` (Dock kept hidden, parked windows kept parked).
@MainActor
public final class UpdateService {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Updates.Release)
        case installing(String)
        case failed(String)
    }

    public private(set) var status: Status = .idle {
        didSet { onChange() }
    }
    public var onChange: () -> Void = {}
    /// The releases newer than this Pavé, newest first (their notes).
    public private(set) var newer: [Updates.Release] = []
    public var source = Updates.defaultSource

    public let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?
    static let interval: TimeInterval = 24 * 3600

    public init() {}

    /// The installed copy (~/Applications or /Applications): a dev build is
    /// replaced by every `just run`, it never updates itself.
    public static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    /// Checks 30 s after launch, then once a day; or stops.
    public func schedule(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let first = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check(quiet: true)
                self?.timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check(quiet: true) }
                }
            }
        }
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    // MARK: Check

    /// Why this copy does not update itself, if it does not: signed with
    /// another certificate than the releases (built from source).
    public static let notUpdatable: String? = {
        guard let url = Bundle.main.url(forResource: "update-cert", withExtension: "sha256"),
            let expected = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return "this copy carries no release certificate: it updates from your own builds" }
        guard let mine = signingCertificateSHA256() else { return "this copy is not signed with a certificate: it updates from your own builds" }
        return mine == expected
            ? nil : "this copy is signed with another certificate than Pavé's releases (built from source): it updates from your own builds"
    }()

    /// SHA-256 of the leaf certificate this app is signed with.
    nonisolated static func signingCertificateSHA256() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `quiet`: a scheduled check, whose failure (offline, gh missing) only goes to the log.
    public func check(quiet: Bool = false, then: (@MainActor (Status) -> Void)? = nil) {
        if case .installing = status { return }
        if let why = Self.notUpdatable {
            if !quiet {
                Log.info("update: not checked, \(why)")
                status = .failed(why)
            }
            then?(status)
            return
        }
        let previous = status
        status = .checking
        let source = source, current = current
        Task.detached {
            let result: Result<[Updates.Release], Error>
            do {
                let json = try await Self.github("repos/\(source)/releases?per_page=30")
                result = .success(try Updates.releases(fromGitHub: json))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success(let releases):
                    self.newer = Updates.newer(releases, than: current)
                    if let latest = self.newer.first {
                        if case .available(let shown) = previous, shown == latest {} else {
                            Log.info("update: Pavé \(latest.version) available (this one: \(current))")
                        }
                        self.status = .available(latest)
                    } else {
                        if !quiet { Log.info("update: Pavé \(current) is up to date (\(source))") }
                        self.status = .upToDate(checked: Date())
                    }
                case .failure(let error):
                    Log.info("update: check FAILED (\(error.localizedDescription))")
                    self.status = quiet ? previous == .checking ? .idle : previous : .failed(error.localizedDescription)
                }
                then?(self.status)
            }
        }
    }

    // MARK: Install

    public func install(_ release: Updates.Release, then: (@MainActor (String?) -> Void)? = nil) {
        guard Self.isInstalledCopy else {
            return fail("this is a development build (\(Bundle.main.bundlePath)): updates install over the copy in Applications", then)
        }
        guard let archive = release.archive else { return fail("Pavé \(release.version) has no signed archive", then) }
        guard let keyURL = Bundle.main.url(forResource: "update-key", withExtension: "pub"),
            let keyText = try? String(contentsOf: keyURL, encoding: .utf8)
        else { return fail("this Pavé has no update key: install from the release page", then) }
        status = .installing(release.version)
        Log.info("update: installing Pavé \(release.version)")
        let source = source, app = URL(fileURLWithPath: Bundle.main.bundlePath)
        Task.detached {
            do {
                let key = try Minisign.PublicKey(keyText)
                let bytes = try await Self.github("repos/\(source)/releases/assets/\(archive.file.id)", binary: true)
                let sigText = String(decoding: try await Self.github("repos/\(source)/releases/assets/\(archive.signature.id)", binary: true), as: UTF8.self)
                try Minisign.verify(bytes, signature: try Minisign.Signature(sigText), key: key, trustedComment: "file:\(archive.file.name)")
                try Self.replace(app, with: bytes)
                await MainActor.run {
                    Log.info("update: Pavé \(release.version) installed, restarting")
                    then?(nil)
                    self.restartNow(app)
                }
            } catch {
                await MainActor.run { self.fail("Pavé \(release.version) NOT installed: \(error)", then) }
            }
        }
    }

    private func fail(_ message: String, _ then: (@MainActor (String?) -> Void)?) {
        Log.info("update: \(message)")
        status = .failed(message)
        then?(message)
    }

    /// Opens the new app once this one has quit, then quits as for a restart.
    private func restartNow(_ app: URL) {
        do {
            try Relaunch.afterExit(app, reason: "update")
        } catch {
            Log.info("update: cannot relaunch (\(error)): open Pavé again yourself")
        }
    }

    // MARK: - Off the main thread

    struct Failure: LocalizedError, CustomStringConvertible {
        var description: String
        var errorDescription: String? { description }
    }

    /// Replaces `app` with the Pave.app of `archive` (a .tar.gz), after checking
    /// its code signature against this app's designated requirement. The old app
    /// is put back if the new one cannot be moved in.
    nonisolated static func replace(_ app: URL, with archive: Data) throws {
        let parent = app.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".pave-update-\(ProcessInfo.processInfo.processIdentifier)")
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: false)
        } catch {
            throw Failure(description: "\(parent.path) is not writable")
        }
        // Removed at the end, unless it holds the only copy left (see below).
        var keepWork = false
        defer { if !keepWork { try? fm.removeItem(at: work) } }
        let tgz = work.appendingPathComponent("Pave.app.tar.gz")
        try archive.write(to: tgz)
        try run("/usr/bin/tar", ["-xzf", tgz.path, "-C", work.path])
        let new = work.appendingPathComponent("Pave.app")
        guard fm.fileExists(atPath: new.appendingPathComponent("Contents/MacOS/Pave").path) else {
            throw Failure(description: "the archive holds no Pave.app")
        }
        try checkSignature(of: new)
        let old = work.appendingPathComponent("Pavé-previous.app")
        try fm.moveItem(at: app, to: old)
        do {
            try fm.moveItem(at: new, to: app)
        } catch {
            do {
                try fm.moveItem(at: old, to: app)
            } catch {
                // Neither in place: the old app stays where it is, never deleted.
                keepWork = true
                throw Failure(description: "cannot put the new app in place, nor the old one back: it is in \(old.path)")
            }
            throw Failure(description: "cannot put the new app in place (\(error.localizedDescription))")
        }
    }

    /// The new app is validly signed, and satisfies this app's designated requirement.
    public nonisolated static func checkSignature(of app: URL) throws {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
            SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
            SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
            let requirement
        else { throw Failure(description: "cannot read this app's code signature") }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure(description: "cannot read the new app's code signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw Failure(description: "the new app is not signed like this one (\(message))")
        }
    }

    /// A GitHub API path: from the public API first (a public repository
    /// needs no account), else through `gh` (a private one, with the user's
    /// access). `binary`: a release asset's bytes.
    nonisolated static func github(_ path: String, binary: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!, timeoutInterval: 120)
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pave-updater", forHTTPHeaderField: "User-Agent")
        var publicError = "no answer"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            // 404: private (or gone); 403: rate limit. gh may still get it.
            publicError = "GitHub answered \(code)"
        } catch {
            publicError = error.localizedDescription
        }
        do {
            return try gh(binary ? ["api", "-H", "Accept: application/octet-stream", path] : ["api", path])
        } catch let error as Failure where error.description.hasPrefix("the GitHub CLI") {
            throw Failure(description: "\(publicError); a private repository needs the GitHub CLI: brew install gh, then gh auth login")
        }
    }

    /// `gh` with its usual places on the PATH (an app does not get the shell's).
    nonisolated static func gh(_ args: [String]) throws -> Data {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(description: "the GitHub CLI (gh) is not installed: brew install gh, then gh auth login")
        }
        return try run(path, args)
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) throws -> Data {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GH_PROMPT_DISABLED"] = "1"
        let result = try Shell.run(path, args, environment: env)
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: path).lastPathComponent
            throw Failure(description: "\(name): \(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return result.output
    }
}
