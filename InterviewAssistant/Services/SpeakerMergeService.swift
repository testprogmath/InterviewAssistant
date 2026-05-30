//
//  SpeakerMergeService.swift
//  InterviewAssistant
//
//  Combines per-track transcripts into one timeline.
//
//  This is intentionally simple: each input segment already carries its
//  speaker (because we recorded the two sides into separate files), so the
//  whole job is "interleave by startTime". Overlapping speech is preserved
//  — we never try to "resolve" who was speaking when both did.
//

import Foundation

struct SpeakerMergeService {

    /// Merge two timestamped streams into one chronologically ordered
    /// list. Optional `coalesceWithinGap` collapses adjacent same-speaker
    /// segments whose gap is below the threshold — purely a readability
    /// pass that does not change the underlying timeline.
    func merge(
        interviewer: [TranscriptSegment],
        candidate:   [TranscriptSegment],
        coalesceWithinGap: TimeInterval? = 0.4
    ) -> [TranscriptSegment] {

        var combined = (interviewer + candidate)
            .sorted { $0.startTime < $1.startTime }

        guard let gap = coalesceWithinGap, gap > 0, !combined.isEmpty else {
            return combined
        }

        // One pass — fold runs of same-speaker segments separated by ≤ gap.
        var result: [TranscriptSegment] = []
        result.reserveCapacity(combined.count)
        result.append(combined.removeFirst())

        for seg in combined {
            let last = result[result.count - 1]
            let canJoin =
                last.speaker == seg.speaker &&
                (seg.startTime - last.endTime) <= gap

            if canJoin {
                let joined = TranscriptSegment(
                    id: last.id,
                    speaker: last.speaker,
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    text: last.text + " " + seg.text,
                    confidence: averageConfidence(last.confidence, seg.confidence)
                )
                result[result.count - 1] = joined
            } else {
                result.append(seg)
            }
        }
        return result
    }

    private func averageConfidence(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (let x?, let y?): return (x + y) / 2
        case (let x?, nil):    return x
        case (nil, let y?):    return y
        case (nil, nil):       return nil
        }
    }
}
