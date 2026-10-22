"""Synthetic catalog fixtures only; never reads or overwrites production catalogs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class LocalizationGeneratorTests(unittest.TestCase):
    """Validate catalog encoding and format contracts using synthetic translations."""
    # --- Synthetic catalogs and deterministic encoding ---

    def setUp(self):
        """Load the generator and create isolated catalog and header paths."""
        spec = importlib.util.spec_from_file_location("localization_generator", PROJECT / "scripts/generate_localizations.py")
        self.generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.generator)
        self.temporary = tempfile.TemporaryDirectory(prefix="localization-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "generated/Localization.h"

    def write(self, ko, en):
        """Write paired Korean and English fixture catalogs as UTF-8 JSON."""
        for language, catalog in (("ko", ko), ("en", en)):
            (self.directory / f"{language}.json").write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")

    def test_deterministic_utf8_json_and_hash_ignore_input_key_order(self):
        """Check deterministic bytes, hash and unchanged-file timestamps across input key ordering."""
        ko = {"나 %@": "나 %@", "가": "가"}
        en = {"나 %@": "fixture %@", "가": "fixture"}
        self.write(ko, en)
        digest = self.generator.generate(self.directory, self.output)
        first = self.output.read_bytes()
        stamp = self.output.stat().st_mtime_ns
        self.write(dict(reversed(list(ko.items()))), dict(reversed(list(en.items()))))
        self.assertEqual(self.generator.generate(self.directory, self.output), digest)
        self.assertEqual(self.output.read_bytes(), first)
        self.assertEqual(self.output.stat().st_mtime_ns, stamp)
        self.assertIn(b"kCRDLocalizationJSON", first)
        self.assertIn(digest.encode(), first)

    def test_escaped_header_roundtrip_preserves_arbitrary_body_text(self):
        """Check that quotes, Unicode, escapes and delimiter text survive header encoding."""
        key = '가 "나" \\ 경로\n%@ %% )CRDLOCALIZATION" ☃'
        value = 'fixture "quote" \\ path\n%@ %% )CRDLOCALIZATION" ☃'
        self.write({key: key}, {key: value})
        self.generator.generate(self.directory, self.output)
        line = next(line for line in self.output.read_text(encoding="utf-8").splitlines() if line.startswith("static const char kCRDLocalizationJSON"))
        raw = json.loads(line.split(" = ", 1)[1][:-1])
        self.assertEqual(json.loads(raw), {"ko": {key: key}, "en": {key: value}})

    # --- Catalog validation and printf contracts ---

    def test_missing_extra_duplicate_and_blank_entries_are_rejected(self):
        """Check invalid key sets, duplicate entries and empty or non-string translations."""
        for ko, en in (({"가": "가"}, {}), ({"가": "가"}, {"나": "fixture"}), ({"가": "가"}, {"가": " "}), ({"가": "가"}, {"가": 1})):
            with self.subTest(en=en):
                self.write(ko, en)
                with self.assertRaises(ValueError):
                    self.generator.generate(self.directory, self.output)
        self.write({"가": "가"}, {"가": "fixture"})
        (self.directory / "en.json").write_text('{"가":"fixture","가":"duplicate"}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.generator.generate(self.directory, self.output)
        self.assertFalse(self.output.exists())

    def test_ko_identity_is_required_and_invalid_translation_preserves_last_header(self):
        """Check source-key identity and preservation of the last header on validation failure."""
        self.write({"가 %@": "가 %@"}, {"가 %@": "fixture %@"})
        self.generator.generate(self.directory, self.output)
        saved = self.output.read_bytes()
        self.write({"가 %@": "다른 값 %@"}, {"가 %@": "fixture %@"})
        with self.assertRaisesRegex(ValueError, "identity"):
            self.generator.generate(self.directory, self.output)
        self.assertEqual(self.output.read_bytes(), saved)

    def test_printf_count_type_and_unnumbered_order_must_match(self):
        """Check rejection of printf argument count, type and implicit-order mismatches."""
        for key, value in (("가 %@ %@", "fixture %@"), ("가 %@", "fixture %d"), ("가 %@ %ld", "fixture %ld %@"), ("가 %@ %@", "%1$@ %1$@")):
            with self.subTest(key=key, value=value):
                self.write({key: key}, {key: value})
                with self.assertRaisesRegex(ValueError, "printf"):
                    self.generator.generate(self.directory, self.output)

    def test_printf_positional_reordering_width_precision_and_percent_escape(self):
        """Check valid positional arguments, dynamic fields and percent escapes, rejecting invalid positions."""
        pairs = (("가 %@ %ld", "%2$ld fixture %1$@"), ("가 %*.*f", "%3$*1$.*2$f fixture"), ("가 %@ %%", "%% fixture %@"), ("100%", "100%"))
        for key, value in pairs:
            with self.subTest(key=key):
                self.write({key: key}, {key: value})
                self.generator.generate(self.directory, self.output)
        for value in ("%1$@ %@", "%0$@"):
            with self.subTest(invalid=value):
                self.write({"가 %@ %@": "가 %@ %@"}, {"가 %@ %@": value})
                with self.assertRaises(ValueError):
                    self.generator.generate(self.directory, self.output)


if __name__ == "__main__":
    unittest.main()
