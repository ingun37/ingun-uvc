import Testing
@testable import time_mapper

struct TimeMapperTests {
    @Test func parsesClockFormatsAndRejectsInvalidSeconds() {
        #expect(GameTimeMapper.parseClock(["07 : 20"]) == 440)
        #expect(GameTimeMapper.parseClock([":06.1"]) == 6)
        #expect(GameTimeMapper.parseClock(["07", ":", "20"]) == 440)
        #expect(GameTimeMapper.parseClock(["00:00"]) == 0)
        #expect(GameTimeMapper.parseClock(["07:60"]) == nil)
        #expect(GameTimeMapper.parseClock(["no clock"]) == nil)
    }

    @Test func mergesOnlyAdjacentMatchingReadings() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(440, at: 0, until: 0.5, to: &entries)
        GameTimeMapper.add(440, at: 0.5, until: 1, to: &entries)
        GameTimeMapper.add(440, at: 2, until: 2.5, to: &entries)
        #expect(entries.count == 2)
        #expect(entries[0].end_seconds == 1)
        #expect(entries[1].start_seconds == 2)
    }
}
