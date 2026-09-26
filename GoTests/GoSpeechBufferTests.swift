import Testing
@testable import Go

struct GoSpeechBufferTests {
    @Test func firstSentenceDoesNotWaitForTheWholeReply() {
        var buffer = GoSpeechBuffer()
        #expect(buffer.append("Hey, I'm Go!") == ["Hey, I'm Go!"])
        #expect(buffer.append(" What are we working on?") == ["What are we working on?"])
        #expect(buffer.finish() == nil)
        #expect(buffer.finish() == nil)
    }

    @Test func splitDeltasAndDecimalsKeepTheirText() {
        var buffer = GoSpeechBuffer()
        #expect(buffer.append("Set the width to 8.").isEmpty)
        #expect(buffer.append("5 inches. Then choose ") == ["Set the width to 8.5 inches."])
        #expect(buffer.append("Portrait.").isEmpty)
        #expect(buffer.finish() == "Then choose Portrait.")
    }

    @Test func severalSentencesAndUnicodeRemainInOrder() {
        var buffer = GoSpeechBuffer()
        #expect(buffer.append("Café is open. Ready? Yes! \n") == ["Café is open.", "Ready?", "Yes!"])
        #expect(buffer.finish() == nil)
        #expect(buffer.append("  ").isEmpty)
        #expect(buffer.finish() == nil)
    }
}
