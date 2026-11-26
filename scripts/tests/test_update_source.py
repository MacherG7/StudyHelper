"""Tests for scripts/update-source.py (run: python3 -m unittest discover -s scripts/tests)."""
import hashlib, importlib.util, io, json, os, plistlib, struct, tempfile, unittest, zipfile
from contextlib import redirect_stderr, redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("update_source", os.path.join(ROOT, "scripts", "update-source.py"))
us = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(us)

REPO = "MacherG7/StudyHelper"
BUNDLE_ID = "MiloG.StudyHelper1"


def macho(entitlements=None, cputype=0x0100000C):
    """Minimal thin 64-bit Mach-O; with a code signature carrying `entitlements` if given."""
    other_cmd = struct.pack("<II", 0x2, 24) + bytes(16)   # unrelated load command first
    if entitlements is None:
        header = struct.pack("<IiiIIIII", us.MH_MAGIC_64, cputype, 0, 2, 1, len(other_cmd), 0, 0)
        return header + other_cmd
    ent = plistlib.dumps(entitlements)
    blob = struct.pack(">II", us.CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(ent)) + ent
    code_dir = struct.pack(">II", 0xFADE0C02, 8)          # placeholder blob before the entitlements
    first = 12 + 8 * 2
    superblob = struct.pack(">III", us.CSMAGIC_EMBEDDED_SIGNATURE, first + len(code_dir) + len(blob), 2) \
        + struct.pack(">II", 0, first) + struct.pack(">II", 5, first + len(code_dir)) + code_dir + blob
    sig_cmd_size = 16
    dataoff = 32 + len(other_cmd) + sig_cmd_size
    sig_cmd = struct.pack("<IIII", us.LC_CODE_SIGNATURE, sig_cmd_size, dataoff, len(superblob))
    header = struct.pack("<IiiIIIII", us.MH_MAGIC_64, cputype, 0, 2, 2, len(other_cmd) + sig_cmd_size, 0, 0)
    return header + other_cmd + sig_cmd + superblob


def fat(*slices):
    offset = 0x4000
    arches, body = b"", b""
    for i, data in enumerate(slices):
        start = offset + len(body)
        arches += struct.pack(">iiIII", 0x0100000C, i, start, len(data), 14)
        body += data + bytes((-len(data)) % 0x4000)
    head = struct.pack(">II", us.FAT_MAGIC, len(slices)) + arches
    return head + bytes(offset - len(head)) + body


def make_ipa(directory, version="0.1.0", build="1", entitlements=None, bundle_id=BUNDLE_ID, extra_info=None,
             extension=None):
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundleExecutable": "StudyHelper",
        "MinimumOSVersion": "18.0",
        "NSCameraUsageDescription": "Kamera für Lernstoff",
    }
    info.update(extra_info or {})
    path = os.path.join(directory, "StudyHelper-%s-%s.ipa" % (version, build))
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/StudyHelper.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        z.writestr("Payload/StudyHelper.app/StudyHelper", macho(entitlements))
        if extension:
            ext_info, ext_entitlements = extension
            z.writestr("Payload/StudyHelper.app/PlugIns/Share.appex/Info.plist", plistlib.dumps(ext_info))
            z.writestr("Payload/StudyHelper.app/PlugIns/Share.appex/Share", macho(ext_entitlements))
    return path


def template():
    """The real source without its published versions (it is the live source, D-034)."""
    with open(os.path.join(ROOT, "distribution", "source.json"), encoding="utf-8") as f:
        source = json.load(f)
    for app in source.get("apps", []):
        app["versions"] = []
    return source


class EntitlementTests(unittest.TestCase):
    def test_unsigned_binary_has_no_entitlements(self):
        """Unsignierte Programmdatei: keine Entitlements"""
        self.assertEqual(us.entitlements_of(macho()), set())

    def test_reads_entitlements_from_signature(self):
        """Entitlements aus der Code-Signatur lesen"""
        keys = us.entitlements_of(macho({"get-task-allow": True, "application-identifier": "T.x"}))
        self.assertEqual(keys, {"get-task-allow", "application-identifier"})

    def test_fat_binary_merges_slices(self):
        """Universal-Binary: Entitlements aller Slices"""
        data = fat(macho({"a": True}), macho({"b": True}))
        self.assertEqual(us.entitlements_of(data), {"a", "b"})

    def test_rejects_non_macho(self):
        """Keine Mach-O-Datei wird abgelehnt"""
        with self.assertRaises(us.SourceError):
            us.entitlements_of(b"#!/bin/sh\necho hi\n")


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_adds_version_with_metadata_from_ipa(self):
        """Neue Version mit Daten aus der .ipa, Hash und Größe"""
        ipa = make_ipa(self.dir, entitlements={"application-identifier": "T.MiloG.StudyHelper1",
                                               "com.apple.developer.team-identifier": "T",
                                               "get-task-allow": True, "keychain-access-groups": ["T.*"]})
        meta = us.read_ipa(ipa)
        source = template()
        tag, asset = us.add_version(source, meta, REPO, "Neu: Absätze", "2026-11-24T12:00:00Z")
        self.assertEqual((tag, asset), ("v0.1.0.1", "StudyHelper-0.1.0.1.ipa"))
        app = source["apps"][0]
        newest = app["versions"][0]
        with open(ipa, "rb") as f:
            raw = f.read()
        self.assertEqual(newest["version"], "0.1.0")
        self.assertEqual(newest["buildVersion"], "1")
        self.assertEqual(newest["size"], len(raw))
        self.assertNotIn("sha256", newest)  # optional; StikStore rejected it (D-035)
        self.assertEqual(newest["minOSVersion"], "18.0")
        self.assertEqual(newest["downloadURL"],
                         "https://github.com/%s/releases/download/v0.1.0.1/StudyHelper-0.1.0.1.ipa" % REPO)
        # AltStore ignores only application-identifier and the team identifier.
        self.assertEqual(app["appPermissions"]["entitlements"], ["get-task-allow", "keychain-access-groups"])
        self.assertEqual(app["appPermissions"]["privacy"], {"NSCameraUsageDescription": "Kamera für Lernstoff"})
        self.assertEqual(app["downloadURL"], newest["downloadURL"])
        self.assertEqual(app["versionDate"], "2026-11-24T12:00:00Z")
        self.assertEqual(source["sourceURL"], "https://raw.githubusercontent.com/%s/main/distribution/source.json" % REPO)
        self.assertEqual(us.check(source), [])

    def test_newest_version_first(self):
        """Neueste Version steht vorn"""
        source = template()
        us.add_version(source, us.read_ipa(make_ipa(self.dir, build="1")), REPO, "a", "2026-11-24T12:00:00Z")
        us.add_version(source, us.read_ipa(make_ipa(self.dir, build="2")), REPO, "b", "2026-11-25T12:00:00Z")
        self.assertEqual([v["buildVersion"] for v in source["apps"][0]["versions"]], ["2", "1"])
        self.assertEqual(source["apps"][0]["versionDescription"], "b")

    def test_duplicate_version_rejected_unless_replace(self):
        """Gleiche Version und Build nur mit --replace"""
        source = template()
        meta = us.read_ipa(make_ipa(self.dir))
        us.add_version(source, meta, REPO, "a", "2026-11-24T12:00:00Z")
        with self.assertRaises(us.SourceError):
            us.add_version(source, meta, REPO, "b", "2026-11-24T13:00:00Z")
        us.add_version(source, meta, REPO, "b", "2026-11-24T13:00:00Z", replace=True)
        self.assertEqual(len(source["apps"][0]["versions"]), 1)
        self.assertEqual(source["apps"][0]["versions"][0]["localizedDescription"], "b")

    def test_unknown_bundle_id_rejected(self):
        """Fremde Bundle-ID wird abgelehnt"""
        meta = us.read_ipa(make_ipa(self.dir, bundle_id="MiloG.Other"))
        with self.assertRaises(us.SourceError):
            us.add_version(template(), meta, REPO, "a", "2026-11-24T12:00:00Z")

    def test_extension_permissions_included(self):
        """Berechtigungen von App-Erweiterungen kommen mit"""
        ext_info = {"CFBundleExecutable": "Share", "CFBundleIdentifier": BUNDLE_ID + ".Share",
                    "NSMicrophoneUsageDescription": "Mikrofon"}
        meta = us.read_ipa(make_ipa(self.dir, extension=(ext_info, {"com.apple.security.application-groups": []})))
        self.assertEqual(meta["entitlements"], ["com.apple.security.application-groups"])
        self.assertEqual(set(meta["privacy"]), {"NSCameraUsageDescription", "NSMicrophoneUsageDescription"})
        self.assertEqual(meta["bundleIdentifier"], BUNDLE_ID)

    def test_invalid_repo_rejected(self):
        """Repository muss Besitzer/Name sein"""
        with self.assertRaises(us.SourceError):
            us.add_version(template(), us.read_ipa(make_ipa(self.dir)), "https://evil/x", "a", "d")

    def test_main_writes_output_and_shell_assignments(self):
        """Kommandozeile: schreibt Source und Shell-Variablen"""
        ipa = make_ipa(self.dir, version="0.2.0", build="7")
        src = os.path.join(self.dir, "source.json")
        us.save(template(), src)
        out = os.path.join(self.dir, "out.json")
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = us.main(["--ipa", ipa, "--source", src, "--output", out, "--repo", REPO, "--notes", "Text mit 'Quote'"])
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertIn("TAG=v0.2.0.7", stdout.getvalue())
        self.assertIn("TITLE='StudyHelper 0.2 Beta 7'", stdout.getvalue())
        self.assertEqual(us.load(src)["apps"][0]["versions"], [])   # input untouched
        self.assertEqual(us.load(out)["apps"][0]["versions"][0]["localizedDescription"], "Text mit 'Quote'")

    def test_main_reports_errors_without_traceback(self):
        """Kaputte .ipa: Fehlermeldung statt Absturz"""
        bad = os.path.join(self.dir, "bad.ipa")
        with open(bad, "wb") as f:
            f.write(b"kein zip")
        src = os.path.join(self.dir, "source.json")
        us.save(template(), src)
        stderr = io.StringIO()
        with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
            code = us.main(["--ipa", bad, "--source", src, "--repo", REPO])
        self.assertEqual(code, 1)
        self.assertIn("Fehler:", stderr.getvalue())


class ChannelTests(unittest.TestCase):
    """Stable and beta entries for StikStore (D-042)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def add(self, source, build, channel, date="2026-11-26T12:00:00Z", version="1.0.0"):
        meta = us.read_ipa(make_ipa(self.dir, version=version, build=build))
        return us.add_version(source, meta, REPO, "Build %s" % build, date, channel=channel)

    def test_template_has_only_beta_entry(self):
        """Ohne Vollversion gibt es nur den Beta-Eintrag"""
        stable, beta = us.entries(template(), BUNDLE_ID)
        self.assertIsNone(stable)
        self.assertTrue(beta["beta"])
        self.assertEqual(beta["name"], "StudyHelper Beta")

    def test_beta_only_in_beta_entry(self):
        """Eine Beta landet nur im Beta-Eintrag, die News nennt keine stabile Version"""
        source = template()
        self.add(source, "3", "beta")
        stable, beta = us.entries(source, BUNDLE_ID)
        self.assertIsNone(stable)
        self.assertEqual([v["buildVersion"] for v in beta["versions"]], ["3"])
        news = source["news"][0]
        self.assertEqual(news["identifier"], us.NEWS_ID)
        self.assertEqual(news["caption"], "Neueste: 1.0 Beta 3 · Stabil: noch keine · Beta: 1.0 Beta 3")

    def test_first_final_creates_stable_entry(self):
        """Die erste Vollversion legt den stabilen Eintrag an und steht auch im Beta-Eintrag"""
        source = template()
        self.add(source, "3", "beta", "2026-11-26T10:00:00Z")
        self.add(source, "4", "final", "2026-11-27T10:00:00Z")
        stable, beta = us.entries(source, BUNDLE_ID)
        self.assertEqual(stable["name"], "StudyHelper")
        self.assertIs(stable["beta"], False)
        self.assertEqual(stable["bundleIdentifier"], BUNDLE_ID)
        self.assertEqual([v["buildVersion"] for v in stable["versions"]], ["4"])
        self.assertEqual([v["buildVersion"] for v in beta["versions"]], ["4", "3"])
        self.assertEqual(stable["appPermissions"], beta["appPermissions"])
        self.assertLess(source["apps"].index(stable), source["apps"].index(beta))
        self.assertEqual(source["news"][0]["caption"], "Neueste: 1.0 · Stabil: 1.0 · Beta: 1.0 Beta 3")
        self.assertEqual(us.check(source), [])

    def test_beta_after_final(self):
        """Eine Beta nach der Vollversion: neueste insgesamt ist die Beta, stabil bleibt die Vollversion"""
        source = template()
        self.add(source, "4", "final", "2026-11-27T10:00:00Z")
        self.add(source, "5", "beta", "2026-11-28T10:00:00Z", version="1.0.1")
        stable, beta = us.entries(source, BUNDLE_ID)
        self.assertEqual([v["buildVersion"] for v in stable["versions"]], ["4"])
        self.assertEqual(beta["version"], "1.0.1")
        self.assertEqual(source["news"][0]["caption"], "Neueste: 1.0.1 Beta 5 · Stabil: 1.0 · Beta: 1.0.1 Beta 5")
        self.assertEqual(len([n for n in source["news"] if n["identifier"] == us.NEWS_ID]), 1)

    def test_other_news_kept(self):
        """Eigene News bleiben erhalten"""
        source = template()
        source["news"] = [{"title": "Hallo", "identifier": "eigene", "caption": "x", "date": "2026-11-25"}]
        self.add(source, "3", "beta")
        self.assertEqual([n["identifier"] for n in source["news"]], [us.NEWS_ID, "eigene"])

    def test_main_final_title(self):
        """Kommandozeile: --channel final gibt den Titel der Vollversion"""
        ipa = make_ipa(self.dir, version="1.0.0", build="4")
        src = os.path.join(self.dir, "source.json")
        us.save(template(), src)
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            code = us.main(["--ipa", ipa, "--source", src, "--repo", REPO, "--channel", "final"])
        self.assertEqual(code, 0)
        self.assertIn("TITLE='StudyHelper 1.0'", stdout.getvalue())
        self.assertIsNotNone(us.entries(us.load(src), BUNDLE_ID)[0])

    def test_check_allows_one_stable_and_one_beta(self):
        """Eine Bundle-ID darf je einmal stabil und Beta vorkommen, nicht zweimal Beta"""
        source = template()
        self.add(source, "4", "final")
        self.assertEqual(us.check(source), [])
        source["apps"].append(json.loads(json.dumps(us.entries(source, BUNDLE_ID)[1])))
        self.assertIn("eindeutig", " ".join(us.check(source)))
        source["apps"].pop()
        source["apps"][0]["beta"] = "ja"
        self.assertIn("true oder false", " ".join(us.check(source)))


class NightlyTests(unittest.TestCase):
    """Nightly entry with only the newest untested build (D-045)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def add(self, source, build, channel):
        meta = us.read_ipa(make_ipa(self.dir, version="0.0.2", build=build))
        return us.add_version(source, meta, REPO, "Build %s" % build, "2026-11-26T12:00:00Z", channel=channel)

    def test_nightly_creates_own_entry_with_one_version(self):
        """Nightly: eigener Eintrag mit Beta-Markierung, nur die neueste Version, festes Release nightly"""
        source = template()
        self.assertEqual(self.add(source, "7", "nightly"), ("nightly", "StudyHelper-nightly.ipa"))
        self.add(source, "8", "nightly")
        night = us.nightly_entry(source, BUNDLE_ID)
        self.assertEqual(night["name"], "StudyHelper Nightly")
        self.assertIs(night["beta"], True)
        self.assertEqual(night["channel"], "nightly")
        self.assertEqual([v["buildVersion"] for v in night["versions"]], ["8"])
        self.assertEqual(night["downloadURL"],
                         "https://github.com/%s/releases/download/nightly/StudyHelper-nightly.ipa" % REPO)
        stable, beta = us.entries(source, BUNDLE_ID)
        self.assertIsNone(stable)
        self.assertEqual(beta["versions"], [])
        self.assertIn("Nightly: 0.0.2 Nightly 8", source["news"][0]["caption"])
        self.assertEqual(us.check(source), [])

    def test_beta_after_nightly_keeps_nightly(self):
        """Eine getestete Beta landet im Beta-Eintrag, die Nightly bleibt"""
        source = template()
        self.add(source, "7", "nightly")
        self.add(source, "7", "beta")
        _, beta = us.entries(source, BUNDLE_ID)
        self.assertEqual([v["buildVersion"] for v in beta["versions"]], ["7"])
        self.assertIsNotNone(us.nightly_entry(source, BUNDLE_ID))
        self.assertEqual(us.check(source), [])

    def test_main_nightly_title(self):
        """Kommandozeile: --channel nightly gibt Titel und Release nightly"""
        ipa = make_ipa(self.dir, version="0.0.2", build="7")
        src = os.path.join(self.dir, "source.json")
        us.save(template(), src)
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            code = us.main(["--ipa", ipa, "--source", src, "--repo", REPO, "--channel", "nightly"])
        self.assertEqual(code, 0)
        self.assertIn("TITLE='StudyHelper 0.0.2 Nightly 7'", stdout.getvalue())
        self.assertIn("TAG=nightly", stdout.getvalue())


class CheckTests(unittest.TestCase):
    def test_repository_source_is_valid(self):
        """distribution/source.json ist gültig"""
        self.assertEqual(us.check(template()), [])

    def test_repository_source_matches_project(self):
        """Bundle-ID und Kamera-Text wie in project.yml"""
        with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
            project = f.read()
        app = template()["apps"][0]
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: %s\n" % app["bundleIdentifier"], project)
        for key, text in app["appPermissions"]["privacy"].items():
            self.assertIn("%s: %s\n" % (key, text), project)

    def test_detects_problems(self):
        """Fehlende Felder und doppelte Versionen werden gemeldet"""
        source = template()
        app = source["apps"][0]
        del app["developerName"]
        app["category"] = "education"
        version = {"version": "1", "buildVersion": "1", "date": "d", "downloadURL": "http://x", "size": 0}
        app["versions"] = [version, dict(version)]
        problems = " ".join(us.check(source))
        for fragment in ("developerName", "category", "doppelt", "size", "https"):
            self.assertIn(fragment, problems)


if __name__ == "__main__":
    unittest.main()
