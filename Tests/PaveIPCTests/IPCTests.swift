import Foundation
import PaveCore
import Testing

@testable import PaveIPC

private func store(title: String) -> WindowStore {
    var store = WindowStore()
    store.apply(
        AppSnapshot(
            pid: 7,
            windows: [
                WindowSnapshot(
                    id: WindowID(42), pid: 7, appName: "Mail", title: title,
                    frame: Rect(x: 0, y: 0, width: 800, height: 600), state: .normal,
                    subrole: "AXStandardWindow")
            ], focusedWindow: WindowID(42)),
        isFrontmost: true)
    return store
}

@Suite struct DumpTests {
    @Test func titlesAreOmittedUnlessRequested() throws {
        let apps = [Dump.App(pid: 7, name: "Mail", responsive: true)]
        let hidden = Dump(store: store(title: "Re: devis Acme"), apps: apps, build: "1", showTitles: false)
        let json = String(decoding: try IPCCoding.encoder().encode(hidden), as: UTF8.self)
        #expect(!json.contains("Acme"))
        #expect(hidden.windows.first?.title == nil)
        #expect(hidden.windows.first?.titleLength == 14)

        let shown = Dump(store: store(title: "Re: devis Acme"), apps: apps, build: "1", showTitles: true)
        #expect(shown.windows.first?.title == "Re: devis Acme")
    }

    @Test func requestRoundTrips() throws {
        let request = IPCRequest(command: .restoreAll)
        let data = try IPCCoding.encoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self) == #"{"command":"restore-all","showTitles":false}"#)
        #expect(try JSONDecoder().decode(IPCRequest.self, from: data) == request)
    }
}

@Suite struct UnixSocketTests {
    @Test func echoOverSocket() throws {
        let path = NSTemporaryDirectory() + "pave-test-\(getpid()).sock"
        let server = try UnixSocket.listen(path: path)
        defer {
            close(server)
            unlink(path)
        }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        let peer = accept(server, nil, nil)
        #expect(peer >= 0)
        defer { close(peer) }
        #expect(UnixSocket.peerIsCurrentUser(peer))

        UnixSocket.writeAll(client, Data("hello\nrest".utf8))
        #expect(UnixSocket.readLine(peer) == Data("hello".utf8))

        var info = stat()
        stat(path, &info)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    /// Regression: a client that hangs up before the answer killed Pavé with SIGPIPE.
    @Test func writingToAClosedPeerDoesNotRaiseSigPipe() throws {
        let path = NSTemporaryDirectory() + "pave-pipe-\(getpid()).sock"
        let server = try UnixSocket.listen(path: path)
        defer {
            close(server)
            unlink(path)
        }

        let client = try UnixSocket.connect(path: path)
        let peer = accept(server, nil, nil)
        defer { close(peer) }
        UnixSocket.noSigPipe(peer)
        close(client)

        // Without SO_NOSIGPIPE the test process itself would die here.
        UnixSocket.writeAll(peer, Data(repeating: 0x41, count: 256 * 1024))
        #expect(UnixSocket.readLine(peer) == nil)
    }
}
