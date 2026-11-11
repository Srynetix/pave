import CryptoKit
import Foundation

/// Checks a minisign signature (https://jedisct1.github.io/minisign/): what
/// `scripts/release.sh` signs Pavé's releases with, and what an update must
/// carry before it is installed.
///
/// Only the default, pre-hashed signatures (`ED`: Ed25519 over the BLAKE2b-512
/// of the file) are accepted, as in Prism; the legacy ones (`Ed`, over the
/// whole file) are refused. The trusted comment is signed too: the release
/// script puts `file:<name>` in it, so a signature cannot be moved to
/// another file.
public enum Minisign {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    public struct PublicKey: Equatable, Sendable {
        public var keyID: [UInt8]
        public var key: [UInt8]

        /// The `.pub` file's text (its comment line is skipped) or its base64 line alone.
        public init(_ text: String) throws(Failure) {
            guard let line = Minisign.payload(text).first, let raw = Data(base64Encoded: line).map(Array.init),
                raw.count == 42
            else {
                throw Failure("not a minisign public key")
            }
            guard raw[0] == 0x45, raw[1] == 0x64 else { throw Failure("not an Ed25519 minisign key") }  // "Ed"
            keyID = Array(raw[2..<10])
            key = Array(raw[10..<42])
        }
    }

    public struct Signature: Equatable, Sendable {
        public var prehashed: Bool
        public var keyID: [UInt8]
        public var signature: [UInt8]
        public var trustedComment: String
        public var globalSignature: [UInt8]

        /// The `.minisig` file's text.
        public init(_ text: String) throws(Failure) {
            let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let sigIndex = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("untrusted comment:") }),
                let raw = Data(base64Encoded: lines[sigIndex]).map(Array.init), raw.count == 74
            else { throw Failure("unreadable signature") }
            switch (raw[0], raw[1]) {
            case (0x45, 0x44): prehashed = true  // "ED"
            case (0x45, 0x64): prehashed = false  // "Ed"
            default: throw Failure("unknown signature algorithm")
            }
            keyID = Array(raw[2..<10])
            signature = Array(raw[10..<74])
            let prefix = "trusted comment: "
            guard sigIndex + 2 < lines.count, lines[sigIndex + 1].hasPrefix(prefix),
                let global = Data(base64Encoded: lines[sigIndex + 2]).map(Array.init), global.count == 64
            else { throw Failure("the signature has no trusted comment") }
            trustedComment = String(lines[sigIndex + 1].dropFirst(prefix.count))
            globalSignature = global
        }
    }

    /// Throws unless `data` was signed with `key`, pre-hashed, and the trusted
    /// comment is `trustedComment` (when given).
    public static func verify(_ data: Data, signature: Signature, key: PublicKey, trustedComment: String? = nil)
        throws(Failure)
    {
        guard signature.keyID == key.keyID else { throw Failure("signed with another key") }
        guard signature.prehashed else { throw Failure("legacy signature (not pre-hashed): refused") }
        guard let ed = try? Curve25519.Signing.PublicKey(rawRepresentation: key.key) else {
            throw Failure("unusable public key")
        }
        guard ed.isValidSignature(signature.signature, for: Blake2b.hash(data)) else {
            throw Failure("the signature does not match the file")
        }
        guard
            ed.isValidSignature(
                signature.globalSignature, for: signature.signature + Array(signature.trustedComment.utf8))
        else {
            throw Failure("the trusted comment was altered")
        }
        if let trustedComment, signature.trustedComment != trustedComment {
            throw Failure("the signature is another file's (\(signature.trustedComment))")
        }
    }

    /// Lines that are not comments.
    private static func payload(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("untrusted comment:") }
    }
}
