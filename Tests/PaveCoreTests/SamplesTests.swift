import Testing

@testable import PaveCore

@Suite struct SamplesTests {
    @Test func keepsTheLatestOnly() {
        var samples = Samples(limit: 3)
        for v in [5.0, 1, 4, 2, 3] { samples.append(v) }
        #expect(samples.count == 5)
        #expect(samples.sorted() == [2, 3, 4])
    }
}
