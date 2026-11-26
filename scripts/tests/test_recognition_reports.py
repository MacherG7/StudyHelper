"""Tests for scripts/recognition-reports.py (run: python3 -m unittest discover -s scripts/tests)."""
import base64, importlib.util, io, json, os, tempfile, unittest
from contextlib import redirect_stderr

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("recognition_reports", os.path.join(ROOT, "scripts", "recognition-reports.py"))
rr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rr)

IMPORT_ID = "11111111-1111-1111-1111-111111111111"
RECT = {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.03}


def entry(**kw):
    base = {"id": "e1", "importID": IMPORT_ID, "page": 2, "rect": RECT, "kind": "misread",
            "recognized": "Das Systen Erde", "expected": "Das System Erde", "source": "report"}
    base.update(kw)
    return base


def report(entries, **kw):
    data = {"format": rr.FORMAT, "version": 1, "createdAt": "2026-11-26T14:00:00Z",
            "app": {"version": "0.0.2.7", "commit": "abc1234", "os": "iOS 27.2", "device": "iPhone17,1"},
            "imports": [{"id": IMPORT_ID, "fileName": "GPG_bearbeitbar.pdf", "kind": "pdf", "pageCount": 3}],
            "entries": entries}
    data.update(kw)
    return data


def run(argv, stdin_text=None):
    lines, err = [], io.StringIO()
    with redirect_stderr(err):
        if stdin_text is not None:
            import sys
            old, sys.stdin = sys.stdin, io.StringIO(stdin_text)
            try:
                code = rr.main(argv, out=lines.append)
            finally:
                sys.stdin = old
        else:
            code = rr.main(argv, out=lines.append)
    return code, "\n".join(lines), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, data):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(data if isinstance(data, str) else json.dumps(data, ensure_ascii=False))
        return path


class ParsingTests(Base):
    def test_file_overview(self):
        code, out, _ = run([self.write("r.json", report([entry(note="Tippfehler"), entry(kind="missing", recognized=None)]))])
        self.assertEqual(code, 0)
        self.assertIn("GPG_bearbeitbar.pdf", out)
        self.assertIn("Seite 2", out)
        self.assertIn("Das Systen Erde → Das System Erde", out)
        self.assertIn("Notiz: Tippfehler", out)
        self.assertIn("falsch gelesen 1", out)
        self.assertIn("fehlt 1", out)

    def test_pasted_chat_object_and_array(self):
        e = entry()
        obj = "Hallo, hier der Bericht\nJSON-Kurzform: " + json.dumps(report([e])) + "\nEnde"
        nxt = "Text\nJSON-Kurzform:\n" + json.dumps([e]) + "\n"
        for text in (obj, nxt):
            code, out, _ = run(["-"], stdin_text=text)
            self.assertEqual(code, 0)
            self.assertIn("Das Systen Erde", out)

    def test_wrong_format_and_version(self):
        for data, msg in ((report([], format="other"), "Unbekanntes Format"),
                          (report([], version=2), "Berichtsversion 2")):
            code, out, err = run([self.write("r.json", data)])
            self.assertEqual(code, 1)
            self.assertIn(msg, err)
            self.assertNotIn("Traceback", err)

    def test_garbage_and_missing_file(self):
        self.assertEqual(run(["-"], stdin_text="nur Text")[0], 1)
        self.assertEqual(run([self.write("x.json", "{kaputt")])[0], 1)
        code, _, err = run([os.path.join(self.tmp.name, "gibt-es-nicht.json")])
        self.assertEqual(code, 1)
        self.assertIn("nicht lesbar", err)

    def test_null_and_missing_optionals_and_unknown_kind(self):
        sparse = {"id": "x", "importID": IMPORT_ID, "page": 4, "kind": "wunderlich", "recognized": None, "expected": None,
                  "note": None, "after": None, "context": None, "imageJPEGBase64": None}
        code, out, _ = run([self.write("r.json", report([sparse, {"page": 1}]))])
        self.assertEqual(code, 0)
        self.assertIn("[Sonstiges] - → -", out)
        self.assertIn("Sonstiges 2", out)

    def test_save_images(self):
        data = b"\xff\xd8jpegdata"
        e = entry(imageJPEGBase64=base64.b64encode(data).decode())
        d = os.path.join(self.tmp.name, "img")
        code, out, _ = run([self.write("r.json", report([e])), "--save-images", d])
        self.assertEqual(code, 0)
        with open(os.path.join(d, "S2-1-misread.jpg"), "rb") as f:
            self.assertEqual(f.read(), data)


class BenchTests(Base):
    def bench(self):
        return {"file": "GPG_bearbeitbar.pdf", "seconds": 1.0, "pages": [
            {"page": 2, "lines": [
                {"text": "Das Systen Erde", "rect": [0.1, 0.2, 0.5, 0.03], "status": "confident", "reasons": []},
                {"text": "ganz woanders", "rect": [0.1, 0.8, 0.5, 0.03], "status": "uncertain", "reasons": []}]}]}

    def test_overlap_and_expected_absent(self):
        code, out, _ = run([self.write("r.json", report([entry()])), "--bench", self.write("b.json", self.bench())])
        self.assertEqual(code, 0)
        self.assertIn("IoU 1.00", out)
        self.assertIn("[confident]: Das Systen Erde", out)
        self.assertNotIn("ganz woanders", out)
        self.assertIn("nein (fehlt noch)", out)

    def test_expected_already_present(self):
        b = self.bench()
        b["pages"][0]["lines"][0]["text"] = "Das System Erde"
        _, out, _ = run([self.write("r.json", report([entry()])), "--bench", self.write("b.json", b)])
        self.assertIn("ja (bereits enthalten)", out)

    def test_import_override_and_mismatch(self):
        b = self.write("b.json", dict(self.bench(), file="Anderes.pdf"))
        r = self.write("r.json", report([entry()]))
        code, _, err = run([r, "--bench", b])
        self.assertEqual(code, 1)
        self.assertIn("Anderes.pdf", err)
        self.assertEqual(run([r, "--bench", b, "--import", "GPG_bearbeitbar.pdf"])[0], 0)


class ReferenceTests(Base):
    def ref(self):
        return {"file": "GPG_bearbeitbar.pdf", "note": "x", "pages": {
            "2": ["Überschrift", "Das Systen Erde", "Dritte Zeile", "Vierte Zeile"],
            "3": ["Unberührt"]}}

    def test_dry_run_shows_diff_without_writing(self):
        ref_path = self.write("g.reference.json", self.ref())
        code, out, _ = run([self.write("r.json", report([entry()])), "--into-reference", ref_path])
        self.assertEqual(code, 0)
        self.assertIn("-Das Systen Erde", out)
        self.assertIn("+Das System Erde", out)
        self.assertIn("Nichts geschrieben", out)
        with open(ref_path) as f:
            self.assertEqual(json.load(f), self.ref())
        self.assertFalse(os.path.exists(ref_path + ".bak"))

    def test_write_with_backup_and_untouched_pages(self):
        ref_path = self.write("g.reference.json", self.ref())
        e2 = entry(id="e2", kind="missing", recognized=None, expected="Neue Zeile", context={"before": "Dritte Zeile"})
        code, out, _ = run([self.write("r.json", report([entry(), e2])), "--into-reference", ref_path, "--write"])
        self.assertEqual(code, 0)
        with open(ref_path) as f:
            new = json.load(f)
        self.assertEqual(new["pages"]["2"], ["Überschrift", "Das System Erde", "Dritte Zeile", "Neue Zeile", "Vierte Zeile"])
        self.assertEqual(new["pages"]["3"], ["Unberührt"])
        with open(ref_path + ".bak") as f:
            self.assertEqual(json.load(f), self.ref())

    def test_order_moves_line_after_anchor(self):
        ref_path = self.write("g.reference.json", self.ref())
        e = entry(kind="order", recognized="Überschrift", expected=None,
                  after={"id": "a", "order": 3, "text": "Dritte Zeile", "rect": RECT})
        code, _, _ = run([self.write("r.json", report([e])), "--into-reference", ref_path, "--write"])
        self.assertEqual(code, 0)
        with open(ref_path) as f:
            self.assertEqual(json.load(f)["pages"]["2"], ["Das Systen Erde", "Dritte Zeile", "Überschrift", "Vierte Zeile"])

    def test_import_mismatch_is_an_error(self):
        ref = dict(self.ref(), file="Anderes.pdf")
        code, _, err = run([self.write("r.json", report([entry()])), "--into-reference", self.write("a.json", ref)])
        self.assertEqual(code, 1)
        self.assertIn("Anderes.pdf", err)

    def test_already_in_reference_is_reported(self):
        ref = self.ref()
        ref["pages"]["2"][1] = "Das System Erde"
        ref_path = self.write("g.json", ref)
        _, out, _ = run([self.write("r.json", report([entry()])), "--into-reference", ref_path])
        self.assertIn("Schon in der Referenz", out)
        self.assertIn("Keine Änderungen", out)


if __name__ == "__main__":
    unittest.main()
