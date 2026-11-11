// SPDX-License-Identifier: MIT OR Apache-2.0
/// Timing samples for the log's p50 / p95 lines: the latest `limit` values
/// only, so a Pavé running for weeks does not keep (and sort) every one.
public struct Samples: Sendable {
    public let limit: Int
    private var values: [Double] = []
    private var next = 0
    /// Samples added since the start (`values` keeps the latest only).
    public private(set) var count = 0

    public init(limit: Int = 1000) {
        precondition(limit > 0)
        self.limit = limit
    }

    public mutating func append(_ value: Double) {
        if values.count < limit {
            values.append(value)
        } else {
            values[next] = value
            next = (next + 1) % limit
        }
        count += 1
    }

    /// The kept samples, sorted.
    public func sorted() -> [Double] { values.sorted() }
}
