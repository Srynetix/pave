// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Testing

@testable import PaveCore

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// A throwaway key made for these tests (`minisign -G -W`), never a release key.
private let testKey = """
    untrusted comment: minisign public key 5ABFAB85E2589474
    RWR0lFjihau/Wsb7czUv0k6wnLiTMUEaRrM+KtRKxB8Yr1hFB+Le7Ptx
    """
private let file = Data("Pavé test archive\n".utf8)
private let signature = """
    untrusted comment: signature from minisign secret key
    RUR0lFjihau/Wt0J/Fpryra9mPgHtqeeP5qGIUWZq2qfa+QJ9bNwRBFlbQDIblXN8be6UGuFdV5YZ16XfzN8Gu50mSyvwwzfPAI=
    trusted comment: file:Pave_0.6.0.app.tar.gz
    RNttm/MY2SibyusUXcyBGpFV8BeoR5HBuNVkxF1NKjrvk7EcY5irBP4GPXR+Xl8M6U9V+MXDriiBXy+zmdymCw==
    """
private let legacy = """
    untrusted comment: signature from minisign secret key
    RWR0lFjihau/Wi6IO09i7uOfYSZlXrPrPcJzVjKD88P+EjkedHC6cpof3BsomdSWsDkJefLtl21D0jrCpIpPqMxrrSt7XHv0owA=
    trusted comment: file:Pave_0.6.0.app.tar.gz
    VCGgcWFkGzT86qfWVkmwGYUW/8GUhMlfNgn118WeH6WSY+A19vJdmH3Y7W/R5FYwdJqabHhWonEiYqdQUwniBg==
    """

@Suite struct Blake2bTests {
    @Test func matchesTheReferenceVectors() {
        #expect(
            hex(Blake2b.hash([UInt8]()))
                == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
        )
        #expect(
            hex(Blake2b.hash(Array("abc".utf8)))
                == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        )
    }

    @Test func handlesBlockBoundaries() {
        // Against Python's hashlib.blake2b, around the 128-byte blocks.
        let expected: [Int: String] = [
            1: "2fa3f686df876995167e7c2e5d74c4c7", 127: "08b38d2c2a521e8a819cdca2d43b52df",
            128: "0be555525cf1e0b9b74d2a743dd1ee31", 129: "31f95aa8eb1487ce670bc3c0c60ef98b",
            255: "89375d001b6041e7e98dcfeb29ebb93c", 256: "f8517f3d1accbf944ef17fc76662f7d9",
            257: "557107f675d4f77c880522bf50dfbcc2", 1000: "b49dc7bf928d7dee879fafc64c1c9308",
        ]
        for (n, prefix) in expected {
            let data = (0..<n).map { UInt8(($0 * 7) % 256) }
            #expect(hex(Blake2b.hash(data)).hasPrefix(prefix), "\(n) bytes")
        }
    }
}

@Suite struct MinisignTests {
    @Test func acceptsAFileSignedWithTheKey() throws {
        let key = try Minisign.PublicKey(testKey)
        try Minisign.verify(
            file, signature: try Minisign.Signature(signature), key: key, trustedComment: "file:Pave_0.6.0.app.tar.gz")
    }

    @Test func refusesAnythingElse() throws {
        let key = try Minisign.PublicKey(testKey)
        let sig = try Minisign.Signature(signature)
        #expect(throws: Minisign.Failure.self) {
            try Minisign.verify(Data("Pavé test archivE\n".utf8), signature: sig, key: key)
        }
        // Moved to another file.
        #expect(throws: Minisign.Failure.self) {
            try Minisign.verify(file, signature: sig, key: key, trustedComment: "file:Pave_0.7.0.app.tar.gz")
        }
        // Trusted comment altered.
        var altered = sig
        altered.trustedComment = "file:Pave_0.7.0.app.tar.gz"
        #expect(throws: Minisign.Failure.self) { try Minisign.verify(file, signature: altered, key: key) }
        // Legacy (not pre-hashed).
        #expect(throws: Minisign.Failure.self) {
            try Minisign.verify(file, signature: try Minisign.Signature(legacy), key: key)
        }
        // Another key: the release key Pavé ships.
        let other = try Minisign.PublicKey("RWRf1KUlSB8zDxlmnXRFoHhRSMja3NL0JNR8Lk9V+fkqWcXLhxRr9GpX")
        #expect(throws: Minisign.Failure.self) { try Minisign.verify(file, signature: sig, key: other) }
        #expect(throws: Minisign.Failure.self) { try Minisign.PublicKey("hello") }
    }
}

@Suite struct UpdatesTests {
    @Test func versionsCompareNumerically() {
        #expect(Version("0.10.0")! > Version("0.9.3")!)
        #expect(Version("1.0")! == Version("1.0.0")!)
        #expect(Version("0.4.0-beta") == nil && Version("") == nil && Version("1..2") == nil)
    }

    @Test func readsReleasesFromGitHub() throws {
        let json = """
            [
              {"tag_name": "pave-v0.5.0", "body": "Notes", "html_url": "https://x/0.5.0", "draft": false, "prerelease": false,
               "assets": [{"name": "Pave_0.5.0.app.tar.gz", "id": 1}, {"name": "Pave_0.5.0.app.tar.gz.minisig", "id": 2}]},
              {"tag_name": "pave-v0.6.0", "draft": true, "assets": []},
              {"tag_name": "pave-v0.5.1-rc", "assets": []},
              {"tag_name": "pave-v0.10.0", "prerelease": true, "assets": []},
              {"tag_name": "other-v9.0.0", "assets": []},
              {"tag_name": "pave-v0.4.0", "assets": [{"name": "Pave_0.4.0.app.tar.gz", "id": 3}]}
            ]
            """
        let list = try Updates.releases(fromGitHub: Data(json.utf8))
        #expect(list.map(\.version) == ["0.5.0", "0.4.0"])
        #expect(list[0].archive?.file.id == 1 && list[0].archive?.signature.id == 2)
        // Unsigned: nothing to install.
        #expect(list[1].archive == nil)
        #expect(Updates.newer(list, than: "0.4.0").map(\.version) == ["0.5.0"])
        #expect(Updates.newer(list, than: "0.5.0").isEmpty)
    }

    @Test func sourcesAreOwnerSlashRepo() {
        #expect(Updates.isValidSource("Srynetix/pave"))
        #expect(!Updates.isValidSource("pave") && !Updates.isValidSource("a/b/c") && !Updates.isValidSource("a/b c"))
        #expect(!Updates.isValidSource("../..") && !Updates.isValidSource("./x"))
    }
}
