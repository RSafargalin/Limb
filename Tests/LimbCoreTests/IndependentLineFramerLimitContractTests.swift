import LimbCore
import Testing

@Suite
struct IndependentLineFramerLimitContractTests {
    @Test(arguments: [-1, Int.min, 0, 8, Int.max])
    func initializerExposesANonnegativeFrameLimit(_ limit: Int) {
        let framer = LineFramer(maxFrameBytes: limit, initialCapacity: 8)
        #expect(framer.maxFrameBytes == max(0, limit))
    }

    @Test
    func zeroLimitSkipsAnEmptyLineAndRejectsANonemptyLine() {
        var framer = LineFramer(maxFrameBytes: 0, initialCapacity: 8)
        #expect(framer.next() == nil)
        #expect(framer.append(Array("\n".utf8)) == 1)
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)

        #expect(framer.append(Array("a\n".utf8)) == 2)
        #expect(framer.next() == .oversized)
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)
    }

    @Test
    func maximumLimitAcceptsAShortFrame() {
        var framer = LineFramer(maxFrameBytes: .max, initialCapacity: 8)
        #expect(framer.next() == nil)
        #expect(framer.append(Array("abc\n".utf8)) == 4)
        guard case .frame(let range)? = framer.next() else {
            Issue.record("Expected a complete three-byte frame")
            return
        }
        #expect(Array(framer.buffer[range]) == Array("abc".utf8))
        #expect(framer.next() == nil)
    }

    @Test(arguments: [-1, Int.min, 0, 8, Int.max])
    func parseOptionsKeepNonnegativeDepthAndNodeLimits(_ limit: Int) {
        let initial = JSONParseOptions(maxDepth: limit, maxNodes: limit)
        #expect(initial.maxDepth == max(0, limit))
        #expect(initial.maxNodes == max(0, limit))

        var updated = JSONParseOptions(maxDepth: 2, maxNodes: 10)
        updated.maxDepth = limit
        updated.maxNodes = limit
        #expect(updated.maxDepth == max(0, limit))
        #expect(updated.maxNodes == max(0, limit))
    }
}
