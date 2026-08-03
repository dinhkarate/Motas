import Testing
@testable import MotasCore

@Test("Refresh requests coalesce into one follow-up batch")
func refreshRequestsCoalesce() {
    var coalescer = RefreshCoalescer()
    let firstRevision = coalescer.begin()
    #expect(firstRevision == 0)

    #expect(coalescer.begin() == nil)
    #expect(coalescer.begin() == nil)
    #expect(coalescer.finish() == true)

    #expect(coalescer.begin() == 0)
    #expect(coalescer.finish() == false)
}

@Test("Configuration change discards in-flight result and requests follow-up")
func configurationChangeDiscardsOldRefresh() {
    var coalescer = RefreshCoalescer()
    let oldRevision = coalescer.begin()!
    coalescer.configurationDidChange()

    #expect(coalescer.shouldApplyResult(capturedAt: oldRevision) == false)
    #expect(coalescer.finish() == true)
    #expect(coalescer.begin() == 1)
}

@Test("Configuration change while idle advances revision without pending batch")
func configurationChangeWhileIdle() {
    var coalescer = RefreshCoalescer()
    coalescer.configurationDidChange()

    #expect(coalescer.begin() == 1)
    #expect(coalescer.finish() == false)
}