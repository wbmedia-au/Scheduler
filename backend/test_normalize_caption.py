"""Unit tests for lambda_function.normalize_caption().

Run directly: python3 test_normalize_caption.py
(or: python3 -m unittest test_normalize_caption)

Importing lambda_function pulls in boto3 and pypdf and requires S3_BUCKET/S3_KEY env
vars (it reads them at module import time), so this sets those up the same way
test_lambda.py does, and stubs out boto3.client so no real AWS client is constructed.
normalize_caption() itself does no I/O, so none of that stubbing affects what's
actually under test here.
"""
import os
import sys
import unittest

sys.path = [p for p in sys.path if "dist-packages" not in p]
sys.path.insert(0, "/tmp/pypdf-isolated")
sys.path.insert(0, "/tmp/boto3-isolated")

os.environ.setdefault("S3_BUCKET", "test-bucket")
os.environ.setdefault("S3_KEY", "scheduler/clients.json")
os.environ.setdefault("AWS_LAMBDA_FUNCTION_NAME", "wb-scheduler-api")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-test-key")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-southeast-2")

import boto3  # noqa: E402

_orig_boto3_client = boto3.client


class _StubNoSuchKey(Exception):
    pass


class _StubS3:
    class exceptions:
        NoSuchKey = _StubNoSuchKey


def _stub_boto3_client(name, *a, **kw):
    if name == "s3":
        return _StubS3()
    return _orig_boto3_client(name, *a, **kw)


boto3.client = _stub_boto3_client

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lambda_function as lf  # noqa: E402

boto3.client = _orig_boto3_client

VS16 = "️"  # emoji variation selector — forces colour (emoji) presentation


class NormalizeCaptionTests(unittest.TestCase):
    def test_wrapped_mid_sentence_line_is_rejoined(self):
        raw = "flavours across\nAsia, our new menu"
        self.assertEqual(lf.normalize_caption(raw), "flavours across Asia, our new menu")

    def test_emoji_ending_line_keeps_the_break(self):
        raw = "Delicious surprises inside \U0001F389\nDon't miss out on this one."
        expected = f"Delicious surprises inside \U0001F389{VS16}\nDon't miss out on this one."
        self.assertEqual(lf.normalize_caption(raw), expected)

    def test_emoji_starting_line_keeps_the_break(self):
        raw = "Check out our full menu online\n\U0001F962 Explore the full Aunties' Kitchen menu at rwc.org.au"
        expected = (
            "Check out our full menu online\n"
            f"\U0001F962{VS16} Explore the full Aunties' Kitchen menu at rwc.org.au"
        )
        self.assertEqual(lf.normalize_caption(raw), expected)

    def test_40_percent_off_wrap_case(self):
        raw = "40% off when\npaying with points."
        self.assertEqual(lf.normalize_caption(raw), "40% off when paying with points.")

    def test_letter_spaced_line_is_repaired(self):
        raw = "Y o u r  c o f f e e"
        self.assertEqual(lf.normalize_caption(raw), "Your coffee")

    def test_sentence_ending_punctuation_keeps_the_break(self):
        raw = (
            "Rogues Sports Bar is the place to be.\n"
            "\U0001F37A Members enjoy 20% off at all Revesby Workers' Club restaurants and bars, or"
        )
        expected = (
            "Rogues Sports Bar is the place to be.\n"
            f"\U0001F37A{VS16} Members enjoy 20% off at all Revesby Workers' Club restaurants and bars, or"
        )
        self.assertEqual(lf.normalize_caption(raw), expected)

    def test_blank_line_paragraph_breaks_are_preserved(self):
        raw = "First paragraph sentence.\n\n✨ Second paragraph line."
        expected = f"First paragraph sentence.\n\n✨{VS16} Second paragraph line."
        self.assertEqual(lf.normalize_caption(raw), expected)

    def test_empty_and_none_are_passed_through(self):
        self.assertEqual(lf.normalize_caption(""), "")
        self.assertIsNone(lf.normalize_caption(None))

    def test_full_real_world_caption_matches_reported_case(self):
        # Drawn directly from the CSV staff reported the line-break bug against
        # (revesby_workers_club_socialpilot_bulk.csv, the Aunties' Kitchen post).
        raw = (
            "Good food tastes even better when it's shared! \U0001F962 ❤\n"
            "At Aunties' Kitchen, the table is always better with a little bit of everything.\n"
            "From fragrant curries and sizzling stir-fries to fresh, vibrant dishes inspired by flavours across\n"
            "Asia, our new menu is made for passing plates, trying something different and enjoying good\n"
            "food with great company \U0001F35C\n"
            "✨ Members enjoy 20% off at all Revesby Workers' Club restaurants and bars, or 40% off when\n"
            "paying with points.\n"
            "\U0001F962 Explore the full Aunties' Kitchen menu at rwc.org.au\n"
            "\U0001F4CD Visit Aunties' Kitchen at Revesby Workers' Club, 2B Brett St, Revesby."
        )
        expected = (
            f"Good food tastes even better when it's shared! \U0001F962{VS16} ❤{VS16}\n"
            "At Aunties' Kitchen, the table is always better with a little bit of everything.\n"
            "From fragrant curries and sizzling stir-fries to fresh, vibrant dishes inspired by flavours across "
            "Asia, our new menu is made for passing plates, trying something different and enjoying good "
            f"food with great company \U0001F35C{VS16}\n"
            f"✨{VS16} Members enjoy 20% off at all Revesby Workers' Club restaurants and bars, or 40% off when "
            "paying with points.\n"
            f"\U0001F962{VS16} Explore the full Aunties' Kitchen menu at rwc.org.au\n"
            f"\U0001F4CD{VS16} Visit Aunties' Kitchen at Revesby Workers' Club, 2B Brett St, Revesby."
        )
        self.assertEqual(lf.normalize_caption(raw), expected)


class ForceEmojiPresentationTests(unittest.TestCase):
    """Covers the reported bug: a heart (and other legacy symbols that double as emoji)
    coming out black/monochrome instead of red/coloured, because pypdf's extraction of
    the Canva PDF drops the invisible emoji variation selector (U+FE0F) that requests
    colour rendering for characters like ❤ ☕ ✨ ⚡ that predate the dedicated emoji
    blocks and default to plain "text presentation" without it."""

    def test_bare_heart_gets_colour_presentation_selector(self):
        raw = "Good food tastes even better when it's shared! \U0001F962 ❤"
        out = lf.normalize_caption(raw)
        self.assertTrue(out.endswith(f"❤{VS16}"), repr(out))

    def test_heart_that_already_has_the_selector_is_not_duplicated(self):
        raw = f"I ❤{VS16} this"
        self.assertEqual(lf.normalize_caption(raw), raw)

    def test_emoji_presentation_default_character_gets_selector_too_harmlessly(self):
        # 🥢 is already emoji-presentation by default (no bare "text style" rendering
        # exists for it), so appending U+FE0F is valid-but-redundant per the Unicode
        # emoji variation sequence spec (UTS #51) rather than something to avoid —
        # applying the fix uniformly (instead of a hardcoded "needs fixing" list) means
        # this case still passes through safely.
        out = lf.normalize_caption("\U0001F962 test")
        self.assertEqual(out, f"\U0001F962{VS16} test")

    def test_skin_tone_modifier_sequence_is_not_split(self):
        # The variation selector must never land between a base emoji and its skin-tone
        # modifier, or the modifier sequence breaks.
        raw = "\U0001F44D\U0001F3FC nice"
        out = lf.normalize_caption(raw)
        self.assertTrue(out.startswith("\U0001F44D\U0001F3FC"), repr(out))
        self.assertNotIn(f"\U0001F44D{VS16}", out)

    def test_two_adjacent_emoji_each_get_their_own_selector(self):
        out = lf.normalize_caption("our books! \U0001F37B \U0001F3C9")
        self.assertEqual(out, f"our books! \U0001F37B{VS16} \U0001F3C9{VS16}")


if __name__ == "__main__":
    unittest.main()
