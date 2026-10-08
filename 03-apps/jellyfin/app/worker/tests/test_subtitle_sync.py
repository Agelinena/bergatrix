from core.subtitle_sync import Cue, align_by_ordinal_map, build_ordinal_time_map, parse_srt, render_srt


def test_parse_and_render_srt():
    cues = parse_srt("1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    assert cues == [Cue(1.0, 2.0, "Hello")]
    assert "00:00:01,000 --> 00:00:02,000" in render_srt(cues)


def test_ordinal_map_handles_different_block_counts():
    reference = [Cue(index * 10, index * 10 + 2, f"ref {index}") for index in range(3)]
    target = [Cue(index * 5, index * 5 + 1, f"target {index}") for index in range(5)]

    points = build_ordinal_time_map(reference, target)
    aligned = align_by_ordinal_map(reference, target)

    assert points
    assert len(aligned) == len(target)
    assert aligned[0].start == 0
    assert aligned[-1].start > aligned[0].start
    assert all(cue.end > cue.start for cue in aligned)
