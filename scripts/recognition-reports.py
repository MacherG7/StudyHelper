#!/usr/bin/env python3
"""Lines up recognition error reports from the app (developer mode) against the local benchmark.

    scripts/recognition-reports.py REPORT|-                      Überblick je Import und Seite
    ... --save-images DIR                                        Ausschnitte als S6-<n>-<kind>.jpg speichern
    ... --bench LocalSamples/bench/RUN.json [--import NAME]      Benchmark-Zeilen im Bereich jedes Eintrags
    ... --into-reference LocalSamples/NAME.reference.json        Änderungen an der Referenz vorschlagen (Diff)
    ... --into-reference REF --write                             Änderungen schreiben (Sicherung REF.bak)

REPORT is a JSON file (format "studyhelper-recognition-report", version 1) or pasted chat text with a line
"JSON-Kurzform:" followed by one line of compact JSON (a report object or an array of entries); "-" reads stdin.
"""
import argparse, base64, difflib, json, os, re, shutil, sys, unicodedata

FORMAT = "studyhelper-recognition-report"
VERSION = 1
KINDS = ["misread", "missing", "order", "split", "highlight", "other"]
KIND_DE = {"misread": "falsch gelesen", "missing": "fehlt", "order": "Reihenfolge", "split": "falsch getrennt",
           "highlight": "Hervorhebung", "other": "Sonstiges"}
MARKER = "JSON-Kurzform:"
ARROW = re.compile(r"-+>|=+>|<-+|<=+")


class ReportError(Exception):
    pass


def words(text):
    """Same word normalization as scripts/score-recognition.py."""
    text = unicodedata.normalize("NFC", text or "").lower()
    text = ARROW.sub(lambda m: " → " if m.group(0).endswith(">") else " ← ", text)
    return re.findall(r"[0-9a-zäöüß]+|[←→↑↓↔↕↗↘↙↖]", text)


def norm(text):
    return " ".join(words(text))


def similarity(a, b):
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


# ---------- parsing ----------

def _json_after_marker(text):
    """Compact JSON following the marker line (same line or the next non-empty one)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if MARKER in line:
            rest = line.split(MARKER, 1)[1].strip()
            j = i + 1
            while not rest and j < len(lines):
                rest = lines[j].strip()
                j += 1
            if not rest:
                raise ReportError("Nach „JSON-Kurzform:“ folgt kein JSON.")
            try:
                return json.loads(rest)
            except json.JSONDecodeError as e:
                raise ReportError(f"Die JSON-Kurzform ist kein gültiges JSON ({e.msg}).")
    return None


def parse_report(text):
    stripped = text.lstrip("﻿ \n\t")
    if MARKER in text:
        data = _json_after_marker(text)
    elif stripped[:1] in ("{", "["):
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError as e:
            raise ReportError(f"Die Datei ist kein gültiges JSON ({e.msg}, Zeile {e.lineno}).")
    else:
        raise ReportError("Weder JSON noch eine Zeile „JSON-Kurzform:“ gefunden.")
    if isinstance(data, list):
        data = {"format": FORMAT, "version": VERSION, "imports": [], "entries": data}
    if not isinstance(data, dict):
        raise ReportError("Unerwarteter Inhalt: erwartet wird ein Bericht (Objekt) oder eine Liste von Einträgen.")
    if data.get("format") != FORMAT:
        raise ReportError(f"Unbekanntes Format „{data.get('format')}“, erwartet „{FORMAT}“.")
    version = data.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version < 1 or version > VERSION:
        raise ReportError(f"Nicht unterstützte Berichtsversion {version}; dieses Skript kennt höchstens Version {VERSION}.")
    entries = data.get("entries") or []
    if not isinstance(entries, list):
        raise ReportError("„entries“ muss eine Liste sein.")
    return {"app": data.get("app") or {}, "createdAt": data.get("createdAt"),
            "imports": [i for i in (data.get("imports") or []) if isinstance(i, dict)],
            "entries": [normalize_entry(e) for e in entries if isinstance(e, dict)]}


def normalize_entry(e):
    kind = e.get("kind") if e.get("kind") in KINDS else "other"
    ctx = e.get("context") if isinstance(e.get("context"), dict) else {}
    rect = e.get("rect")
    if not (isinstance(rect, dict) and all(isinstance(rect.get(k), (int, float)) for k in ("x", "y", "width", "height"))):
        rect = None
    return {
        "id": e.get("id"), "importID": e.get("importID"),
        "page": e.get("page") if isinstance(e.get("page"), int) else 0, "kind": kind, "rect": rect,
        "recognized": e.get("recognized"), "expected": e.get("expected"), "note": e.get("note"),
        "lines": [l for l in (e.get("lines") or []) if isinstance(l, dict)],
        "after": e.get("after") if isinstance(e.get("after"), dict) else None,
        "before": ctx.get("before"), "after_text": ctx.get("after"),
        "source": e.get("source"), "image": e.get("imageJPEGBase64"),
    }


def read_input(path):
    if path == "-":
        return sys.stdin.read()
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise ReportError(f"Datei „{path}“ nicht lesbar: {e.strerror}.")


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError as e:
        raise ReportError(f"{what} „{path}“ nicht lesbar: {e.strerror}.")
    except json.JSONDecodeError as e:
        raise ReportError(f"{what} „{path}“ ist kein gültiges JSON ({e.msg}).")


# ---------- overview ----------

def import_name(report, import_id):
    for i in report["imports"]:
        if i.get("id") == import_id:
            return i.get("fileName") or "?"
    return "unbekannter Import" if import_id else "ohne Import"


def fmt_rect(r):
    if not r:
        return "-"
    return f"x {r['x']:.2f}, y {r['y']:.2f}, b {r['width']:.2f}, h {r['height']:.2f}"


def overview(report, out):
    entries = report["entries"]
    app = report["app"]
    out(f"Erkennungsbericht: {len(entries)} Einträge, {len(report['imports'])} Imports"
        + (f", App {app.get('version', '?')} ({app.get('commit', '?')}), {app.get('os', '?')}" if app else ""))
    groups = {}
    for e in entries:
        groups.setdefault(e["importID"], []).append(e)
    for imp_id, items in groups.items():
        out(f"\n{import_name(report, imp_id)}")
        for page in sorted({e["page"] for e in items}):
            out(f"  Seite {page}")
            for e in (x for x in items if x["page"] == page):
                out(f"    [{KIND_DE[e['kind']]}] {e['recognized'] or '-'} → {e['expected'] or '-'}")
                if e["note"]:
                    out(f"      Notiz: {e['note']}")
                out(f"      Bereich: {fmt_rect(e['rect'])} · Quelle: {e['source'] or '-'}")
    if entries:
        counts = {k: sum(e["kind"] == k for e in entries) for k in KINDS}
        out("\nAnzahl je Art: " + ", ".join(f"{KIND_DE[k]} {n}" for k, n in counts.items() if n))
    else:
        out("\nKeine Einträge.")


def save_images(report, directory, out):
    os.makedirs(directory, exist_ok=True)
    n = 0
    for idx, e in enumerate(report["entries"], 1):
        if not e["image"]:
            continue
        try:
            data = base64.b64decode(e["image"])
        except Exception:
            out(f"Eintrag {idx}: Bild ist nicht lesbar, übersprungen.")
            continue
        path = os.path.join(directory, f"S{e['page']}-{idx}-{e['kind']}.jpg")
        with open(path, "wb") as f:
            f.write(data)
        n += 1
    out(f"{n} Bilder in {directory} gespeichert.")


# ---------- benchmark ----------

def overlap(a, b):
    """a: dict x/y/width/height, b: [x, y, w, h]. Returns (IoU, share of a covered by b, share of b covered by a)."""
    ax, ay, aw, ah = a["x"], a["y"], a["width"], a["height"]
    bx, by, bw, bh = b
    iw = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    ih = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = iw * ih
    union = aw * ah + bw * bh - inter
    return (inter / union if union > 0 else 0.0,
            inter / (aw * ah) if aw * ah > 0 else 0.0,
            inter / (bw * bh) if bw * bh > 0 else 0.0)


def import_ids(report, wanted):
    """IDs of the imports whose file name matches; None if the report has no import list (array form)."""
    if not report["imports"]:
        return None
    ids = {i.get("id") for i in report["imports"] if os.path.basename(i.get("fileName") or "") == os.path.basename(wanted)}
    if not ids:
        raise ReportError(f"Kein Import „{wanted}“ im Bericht (vorhanden: "
                          f"{', '.join(i.get('fileName', '?') for i in report['imports'])}).")
    return ids


def bench_report(report, bench, import_override, out):
    ids = import_ids(report, import_override or bench.get("file", ""))
    pages = {p["page"]: p for p in bench.get("pages", [])}
    out(f"Benchmark: {bench.get('file', '?')}")
    shown = 0
    for e in report["entries"]:
        if ids is not None and e["importID"] not in ids:
            continue
        shown += 1
        out(f"\nSeite {e['page']} [{KIND_DE[e['kind']]}] erkannt: {e['recognized'] or '-'} · erwartet: {e['expected'] or '-'}")
        page = pages.get(e["page"])
        if page is None:
            out("  Seite nicht im Benchmark.")
            continue
        hits = []
        if e["rect"]:
            for l in page.get("lines", []):
                if len(l.get("rect") or []) != 4:
                    continue
                iou, cov, lcov = overlap(e["rect"], l["rect"])
                if iou > 0 or cov >= 0.3 or lcov >= 0.3:
                    hits.append((iou, max(cov, lcov), l))
        hits.sort(key=lambda h: -h[0])
        if not hits:
            out("  Keine Benchmark-Zeile im Bereich.")
        for iou, cov, l in hits:
            out(f"  IoU {iou:.2f}, Überdeckung {cov:.2f} [{l.get('status', '?')}]: {l['text']}")
        if e["expected"]:
            page_text = norm(" ".join(l["text"] for l in page.get("lines", [])))
            exp = norm(e["expected"])
            present = bool(exp) and exp in page_text
            out("  Erwarteter Text im Benchmark: " + ("ja (bereits enthalten)" if present else "nein (fehlt noch)"))
    if shown == 0:
        out("Keine Einträge für diesen Import.")


# ---------- reference ----------

def find_line(lines, text, threshold=0.6, exclude=()):
    best, ratio = None, 0.0
    for i, l in enumerate(lines):
        if i in exclude:
            continue
        r = similarity(l, text)
        if r > ratio:
            best, ratio = i, r
    return best if ratio >= threshold else None


def propose_page(lines, entries):
    """Returns (new_lines, notes) for the reference lines of one page."""
    lines = list(lines)
    notes = []
    for e in entries:
        exp, rec = (e["expected"] or "").strip(), (e["recognized"] or "").strip()
        if e["kind"] == "order":
            moved = rec or (e["lines"][0].get("text", "") if e["lines"] else "")
            anchor = (e["after"] or {}).get("text") or ""
            i = find_line(lines, moved) if moved else None
            j = find_line(lines, anchor, exclude=(i,)) if anchor and i is not None else None
            if i is None or j is None:
                notes.append(f"Reihenfolge übersprungen (Zeile oder Vorgänger nicht in der Referenz): {moved or '-'}")
                continue
            line = lines.pop(i)
            if i < j:
                j -= 1
            lines.insert(j + 1, line)
            continue
        if e["kind"] not in ("misread", "missing", "split") or not exp:
            continue
        new = [p.strip() for p in exp.split("\n") if p.strip()]
        existing = {norm(l) for l in lines}
        if all(norm(p) in existing for p in new):
            notes.append(f"Schon in der Referenz: {exp}")
            continue
        i = find_line(lines, rec) if rec else None
        if i is not None:
            lines[i:i + 1] = new
            continue
        k = find_line(lines, e["before"]) if e["before"] else None
        if k is None and e["after"]:
            k = find_line(lines, e["after"].get("text") or "")
        if k is not None:
            pos = k + 1
        else:
            k = find_line(lines, e["after_text"]) if e["after_text"] else None
            pos = k if k is not None else len(lines)
        lines[pos:pos] = new
    return lines, notes


def into_reference(report, ref_path, write, import_override, out):
    ref = load_json(ref_path, "Referenz")
    if not isinstance(ref.get("pages"), dict):
        raise ReportError(f"Referenz „{ref_path}“ hat kein „pages“.")
    ids = import_ids(report, import_override or ref.get("file", ""))
    pages = ref["pages"]
    changed = False
    selected = [e for e in report["entries"] if ids is None or e["importID"] in ids]
    for page in sorted({e["page"] for e in selected}):
        entries = [e for e in selected if e["page"] == page]
        key = str(page)
        if key not in pages:
            out(f"Seite {page}: nicht in der Referenz, übersprungen.")
            continue
        new, notes = propose_page(pages[key], entries)
        for n in notes:
            out(f"Seite {page}: {n}")
        if new == pages[key]:
            if not notes:
                out(f"Seite {page}: keine Änderung.")
            continue
        out("\n".join(difflib.unified_diff(pages[key], new, f"{ref_path} S.{page} (alt)",
                                           f"{ref_path} S.{page} (neu)", lineterm="")))
        pages[key] = new
        changed = True
    if not changed:
        out("Keine Änderungen vorgeschlagen.")
        return
    if write:
        shutil.copyfile(ref_path, ref_path + ".bak")
        with open(ref_path, "w", encoding="utf-8") as f:
            json.dump(ref, f, ensure_ascii=False, indent=2)
            f.write("\n")
        out(f"Referenz geschrieben, Sicherung: {ref_path}.bak")
    else:
        out("\nNichts geschrieben (Vorschau). Mit --write übernehmen.")


def main(argv=None, out=print):
    p = argparse.ArgumentParser(description="Erkennungsberichte der App mit dem Benchmark abgleichen.")
    p.add_argument("report", help="Berichtsdatei oder - für Standardeingabe")
    p.add_argument("--save-images", metavar="DIR")
    p.add_argument("--bench", metavar="RUN.json")
    p.add_argument("--import", dest="import_name", metavar="NAME",
                   help="Dateiname des Imports (statt der Datei aus Benchmark bzw. Referenz)")
    p.add_argument("--into-reference", metavar="REF.json")
    p.add_argument("--write", action="store_true", help="Änderungen an der Referenz wirklich schreiben")
    args = p.parse_args(argv)
    try:
        report = parse_report(read_input(args.report))
        overview(report, out)
        if args.save_images:
            save_images(report, args.save_images, out)
        if args.bench:
            out("")
            bench_report(report, load_json(args.bench, "Benchmark"), args.import_name, out)
        if args.into_reference:
            out("")
            into_reference(report, args.into_reference, args.write, args.import_name, out)
    except ReportError as e:
        print(f"Fehler: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
