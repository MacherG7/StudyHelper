#!/usr/bin/env python3
"""Maintains the app source for SideStore, AltStore and StikStore (distribution/source.json).

    scripts/update-source.py --ipa build/ipa/StudyHelper-0.0.1.7.ipa --source distribution/source.json \
        --repo MacherG7/StudyHelper [--channel beta|final] [--output OUT.json] [--notes TEXT] [--replace]
    scripts/update-source.py --check distribution/source.json

Update mode reads bundle ID, version, build, minimum iOS, privacy keys and entitlements straight from
the .ipa, adds a new version entry (newest first) with size and SHA-256, and points all URLs at the
public repository: source and icon in its distribution/ folder, the .ipa from the release v<A.B.C.D> that
scripts/beta-release.sh creates (D-034). On success it prints shell assignments (TAG, ASSET, TITLE, VERSION,
BUILD) for scripts/beta-release.sh; messages go to stderr. Format: faq.altstore.io "Make a Source"
(see docs/DECISIONS.md D-024). AltStore refuses to install an app whose bundle ID, version, build or
hash differ from the source, or whose entitlements/privacy keys are not all listed in the source.

Channels (D-042): StikStore marks a whole app entry as beta ("beta": true), not single versions. The source
therefore has up to two entries with the same bundle ID: "StudyHelper Beta" (beta: true) with every release,
newest first – its newest version is the latest overall – and, from the first full version on,
"StudyHelper" (beta: false) with only full versions (latest stable). A news item "studyhelper-versionen"
names the latest, the latest stable and the latest beta version.
"""
import argparse, datetime, hashlib, json, plistlib, posixpath, re, shlex, struct, sys, zipfile

# AltStore ignores these entitlements when comparing the app with the source (VerifyAppOperation).
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}
# Same rule as AltStore: "NS" + name + "UsageDescription" + optional suffix.
PRIVACY_KEY = re.compile(r"^NS.+UsageDescription.*$")
CATEGORIES = {"developer", "entertainment", "games", "lifestyle", "other", "photo-video", "social", "utilities"}

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171


class SourceError(Exception):
    pass


# --- Reading the .ipa --------------------------------------------------------------------------

def entitlements_of(binary):
    """Entitlement keys from the code signature of a (fat or thin) Mach-O; empty when unsigned."""
    if len(binary) < 8:
        raise SourceError("Programmdatei ist zu kurz für Mach-O.")
    keys = set()
    for start in _slice_offsets(binary):
        keys |= set(_slice_entitlements(binary, start))
    return keys


def _slice_offsets(data):
    magic, count = struct.unpack_from(">II", data, 0)
    if magic == FAT_MAGIC:
        return [struct.unpack_from(">iiIII", data, 8 + 20 * i)[2] for i in range(count)]
    if magic == FAT_MAGIC_64:
        return [struct.unpack_from(">iiQQII", data, 8 + 32 * i)[2] for i in range(count)]
    return [0]


def _slice_entitlements(data, start):
    magic = struct.unpack_from("<I", data, start)[0]
    if magic == MH_MAGIC_64:
        offset = start + 32
    elif magic == MH_MAGIC:
        offset = start + 28
    else:
        raise SourceError("Programmdatei ist kein Mach-O (Magic %#x)." % magic)
    ncmds = struct.unpack_from("<I", data, start + 16)[0]
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_CODE_SIGNATURE:
            dataoff = struct.unpack_from("<I", data, offset + 8)[0]
            return _signature_entitlements(data, start + dataoff)
        if size < 8:
            raise SourceError("Beschädigter Mach-O-Ladebefehl.")
        offset += size
    return {}


def _signature_entitlements(data, base):
    magic, _length, count = struct.unpack_from(">III", data, base)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return {}
    for i in range(count):
        _slot, blob_offset = struct.unpack_from(">II", data, base + 12 + 8 * i)
        blob_magic, blob_length = struct.unpack_from(">II", data, base + blob_offset)
        if blob_magic == CSMAGIC_EMBEDDED_ENTITLEMENTS:
            start = base + blob_offset + 8
            return plistlib.loads(data[start:base + blob_offset + blob_length])
    return {}


def read_ipa(path):
    """Metadata AltStore checks, read from the .ipa itself (never from project.yml)."""
    with open(path, "rb") as f:
        raw = f.read()
    with zipfile.ZipFile(path) as ipa:
        names = ipa.namelist()
        apps = sorted({n.split("/")[1] for n in names if re.match(r"^Payload/[^/]+\.app/Info\.plist$", n)})
        if len(apps) != 1:
            raise SourceError("Die .ipa muss genau eine App in Payload/ enthalten (gefunden: %d)." % len(apps))
        app_dir = "Payload/" + apps[0]
        bundles = [app_dir] + sorted(
            posixpath.dirname(n) for n in names
            if re.match(re.escape(app_dir) + r"/PlugIns/[^/]+\.appex/Info\.plist$", n))
        entitlements, privacy, main_info = set(), {}, None
        for bundle in bundles:
            info = plistlib.loads(ipa.read(bundle + "/Info.plist"))
            if bundle == app_dir:
                main_info = info
            for key, value in info.items():
                if PRIVACY_KEY.match(key):
                    privacy.setdefault(key, value)
            executable = info.get("CFBundleExecutable")
            if not executable:
                raise SourceError("%s/Info.plist hat kein CFBundleExecutable." % bundle)
            entitlements |= entitlements_of(ipa.read(bundle + "/" + executable))
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if not main_info.get(key):
            raise SourceError("Info.plist der App hat kein %s." % key)
    return {
        "bundleIdentifier": main_info["CFBundleIdentifier"],
        "version": main_info["CFBundleShortVersionString"],
        "buildVersion": main_info["CFBundleVersion"],
        "minOSVersion": main_info.get("MinimumOSVersion"),
        "entitlements": sorted(entitlements - IGNORED_ENTITLEMENTS),
        "privacy": dict(sorted(privacy.items())),
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


# --- Updating the source -----------------------------------------------------------------------

def urls(repo):
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo):
        raise SourceError("Repository muss die Form Besitzer/Name haben: %r" % repo)
    raw = "https://raw.githubusercontent.com/%s/main/distribution" % repo
    return {
        "source": raw + "/source.json",
        "icon": raw + "/icon.png",
        "website": "https://github.com/" + repo,
        "download": "https://github.com/%s/releases/download/{tag}/{asset}" % repo,
    }


def release_names(meta):
    # Same names as the beta/full releases of scripts/beta-release.sh: v<A.B.C>.<D>, StudyHelper-<A.B.C>.<D>.ipa.
    tag = "v%s.%s" % (meta["version"], meta["buildVersion"])
    asset = "StudyHelper-%s.%s.ipa" % (meta["version"], meta["buildVersion"])
    return tag, asset


CHANNELS = ("beta", "final")
NEWS_ID = "studyhelper-versionen"


def display_name(version, build, final):
    """Name of a release as on GitHub: "0.0.2 Beta 6" or "1.0" (A.B.0 shortened to A.B, D-032)."""
    name = version[:-2] if version.endswith(".0") and version.count(".") == 2 else version
    return name if final else "%s Beta %s" % (name, build)


def entries(source, bundle_id):
    """(stable, beta) app entries of `bundle_id`; either may be None."""
    apps = [a for a in source.get("apps", []) if a.get("bundleIdentifier") == bundle_id]
    stable = next((a for a in apps if not a.get("beta")), None)
    beta = next((a for a in apps if a.get("beta")), None)
    return stable, beta


def stable_entry_from(beta):
    """The stable entry, created from the beta entry with the first full version (D-042)."""
    app = {k: v for k, v in beta.items() if k not in ("versions", "beta", "name", "subtitle")}
    app["name"] = beta["name"].removesuffix(" Beta")
    app["subtitle"] = beta.get("subtitle", "")
    app["beta"] = False
    app["versions"] = []
    return app


def _insert(app, entry, replace):
    versions = app.setdefault("versions", [])
    key = (entry["version"], entry["buildVersion"])
    same = [v for v in versions if (v.get("version"), v.get("buildVersion")) == key]
    if same and not replace:
        raise SourceError(
            "Version %s (%s) steht schon in der Source. MARKETING_VERSION oder CURRENT_PROJECT_VERSION in "
            "project.yml erhöhen (oder --replace)." % key)
    versions[:] = [v for v in versions if v not in same]
    versions.insert(0, dict(entry))
    # Legacy fields mirrored from the newest version for older SideStore/AltStore releases.
    app["version"] = entry["version"]
    app["versionDate"] = entry["date"]
    app["versionDescription"] = entry["localizedDescription"]
    app["downloadURL"] = entry["downloadURL"]
    app["size"] = entry["size"]


def update_news(source, bundle_id, date):
    """News item naming the latest, latest stable and latest beta version (D-042)."""
    stable, beta = entries(source, bundle_id)
    finals = {(v["version"], v["buildVersion"]) for v in (stable or {}).get("versions", [])}
    every = (beta or stable or {}).get("versions", [])
    if not every:
        return
    def name(v):
        return display_name(v["version"], v["buildVersion"], (v["version"], v["buildVersion"]) in finals)
    newest = every[0]
    newest_stable = next((v for v in every if (v["version"], v["buildVersion"]) in finals), None)
    newest_beta = next((v for v in every if (v["version"], v["buildVersion"]) not in finals), None)
    caption = "Neueste: %s · Stabil: %s · Beta: %s" % (
        name(newest), name(newest_stable) if newest_stable else "noch keine",
        name(newest_beta) if newest_beta else "keine")
    item = {
        "title": "Aktuelle Versionen", "identifier": NEWS_ID, "caption": caption, "date": date,
        "tintColor": (beta or stable).get("tintColor", "#2F64E0"), "appID": bundle_id, "notify": False,
    }
    news = [n for n in source.get("news", []) if n.get("identifier") != NEWS_ID]
    source["news"] = [item] + news


def add_version(source, meta, repo, notes, date, replace=False, channel="beta"):
    """Adds the .ipa as newest version of its channel; returns (tag, asset). Mutates `source`.

    A beta goes into the beta entry; a full version into the stable entry (created on the first one) and the
    beta entry, so that the beta entry always offers the latest version overall (D-042)."""
    if channel not in CHANNELS:
        raise SourceError("Kanal muss beta oder final sein: %r" % channel)
    links = urls(repo)
    stable, beta = entries(source, meta["bundleIdentifier"])
    if beta is None:
        raise SourceError("Bundle-ID %s der .ipa steht nicht (als Beta-Eintrag) in der Source." % meta["bundleIdentifier"])

    tag, asset = release_names(meta)
    entry = {
        "version": meta["version"],
        "buildVersion": meta["buildVersion"],
        "date": date,
        "localizedDescription": notes,
        "downloadURL": links["download"].format(tag=tag, asset=asset),
        "size": meta["size"],
        # No "sha256": it is optional in the AltSource format, and StikStore rejected the matching hash
        # ("doesn't match the checksum its source published") although file and source agreed (D-035).
    }
    if meta.get("minOSVersion"):
        entry["minOSVersion"] = meta["minOSVersion"]

    targets = [beta]
    if channel == "final":
        if stable is None:
            stable = stable_entry_from(beta)
            apps = source["apps"]
            apps.insert(apps.index(beta), stable)
        targets.insert(0, stable)
    for app in targets:
        _insert(app, entry, replace)
        app["appPermissions"] = {"entitlements": meta["entitlements"], "privacy": meta["privacy"]}
        app["iconURL"] = links["icon"]
    update_news(source, meta["bundleIdentifier"], date)

    source["sourceURL"] = links["source"]
    source["iconURL"] = links["icon"]
    source["website"] = links["website"]
    return tag, asset


def check(source):
    """Problems that would make SideStore/AltStore/StikStore reject or misread the source."""
    problems = []
    if not isinstance(source, dict):
        return ["Die Source muss ein JSON-Objekt sein."]
    if not source.get("name"):
        problems.append("Source: name fehlt.")
    apps = source.get("apps")
    if not isinstance(apps, list):
        return problems + ["Source: apps fehlt oder ist keine Liste."]
    ids = [a.get("bundleIdentifier") for a in apps]
    # One bundle ID may appear twice: a stable and a beta entry (StikStore marks entries, D-042).
    channels = [(a.get("bundleIdentifier"), bool(a.get("beta"))) for a in apps]
    if len(channels) != len(set(channels)):
        problems.append("Source: Bundle-IDs sind nicht eindeutig (je ID höchstens ein stabiler und ein Beta-Eintrag).")
    for app in apps:
        label = "App %s" % app.get("bundleIdentifier", "?")
        for key in ("name", "bundleIdentifier", "developerName", "localizedDescription", "iconURL"):
            if not app.get(key):
                problems.append("%s: %s fehlt." % (label, key))
        perms = app.get("appPermissions")
        if not isinstance(perms, dict) or not isinstance(perms.get("entitlements"), list) \
                or not isinstance(perms.get("privacy"), dict):
            problems.append("%s: appPermissions braucht entitlements (Liste) und privacy (Objekt)." % label)
        if app.get("category") and app["category"] not in CATEGORIES:
            problems.append("%s: unbekannte category %r." % (label, app["category"]))
        versions = app.get("versions")
        if not isinstance(versions, list):
            problems.append("%s: versions fehlt oder ist keine Liste." % label)
            continue
        seen = set()
        for v in versions:
            key = (v.get("version"), v.get("buildVersion"))
            if key in seen:
                problems.append("%s: Version %s (%s) doppelt." % (label, *key))
            seen.add(key)
            for field in ("version", "buildVersion", "date", "downloadURL"):
                if not v.get(field):
                    problems.append("%s: Version %s ohne %s." % (label, key[0], field))
            if not isinstance(v.get("size"), int) or v["size"] <= 0:
                problems.append("%s: Version %s ohne gültige size." % (label, key[0]))
            if not str(v.get("downloadURL", "")).startswith("https://"):
                problems.append("%s: downloadURL von %s muss https sein." % (label, key[0]))
    for app in apps:
        if "beta" in app and not isinstance(app["beta"], bool):
            problems.append("App %s: beta muss true oder false sein." % app.get("bundleIdentifier", "?"))
    for ident in source.get("featuredApps", []):
        if ident not in ids:
            problems.append("featuredApps: %s ist keine App der Source." % ident)
    return problems


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(source, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", metavar="SOURCE", help="nur prüfen, nichts ändern")
    parser.add_argument("--ipa")
    parser.add_argument("--source")
    parser.add_argument("--output", help="Ziel (Standard: --source überschreiben)")
    parser.add_argument("--repo", help="öffentliches Repository Besitzer/Name")
    parser.add_argument("--notes", default="", help="Was ist neu (Markdown)")
    parser.add_argument("--date", help="Datum ISO 8601 (Standard: jetzt, UTC)")
    parser.add_argument("--replace", action="store_true", help="gleiche Version/Build ersetzen")
    parser.add_argument("--channel", choices=CHANNELS, default="beta", help="beta (Standard) oder final")
    args = parser.parse_args(argv)

    try:
        if args.check:
            problems = check(load(args.check))
            for p in problems:
                print("Fehler: " + p, file=sys.stderr)
            if not problems:
                print("Source in Ordnung: %s" % args.check, file=sys.stderr)
            return 1 if problems else 0

        if not (args.ipa and args.source and args.repo):
            parser.error("--ipa, --source und --repo sind nötig (oder --check).")
        source = load(args.source)
        meta = read_ipa(args.ipa)
        date = args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        notes = args.notes.strip() or "Version %s (%s)" % (meta["version"], meta["buildVersion"])
        tag, asset = add_version(source, meta, args.repo, notes, date, args.replace, args.channel)
        problems = check(source)
        if problems:
            raise SourceError("Source nach dem Update ungültig: " + " ".join(problems))
        save(source, args.output or args.source)
        print("Version %s (%s), %d Bytes, Entitlements: %s, Datenschutz: %s" % (
            meta["version"], meta["buildVersion"], meta["size"],
            ", ".join(meta["entitlements"]) or "keine", ", ".join(meta["privacy"]) or "keine"), file=sys.stderr)
        for key, value in (("TAG", tag), ("ASSET", asset), ("VERSION", meta["version"]),
                           ("BUILD", meta["buildVersion"]),
                           ("TITLE", "StudyHelper " + display_name(meta["version"], meta["buildVersion"],
                                                                    args.channel == "final"))):
            print("%s=%s" % (key, shlex.quote(value)))
        return 0
    except (SourceError, OSError, ValueError, KeyError, zipfile.BadZipFile, struct.error) as error:
        print("Fehler: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
