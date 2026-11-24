#!/usr/bin/env python3
"""Scores a recognition-bench run against a hand-made reference and an earlier run.

    scripts/score-recognition.py RUN.json --ref REF.json [--baseline OLD.json]

Score per page with reference: fuzzy bag-of-words. Each reference word is paired with at most one
recognized word (exact match first, then the most similar one with similarity >= 0.75); a pair counts
with its similarity. Recall = credit / reference words, precision = credit / recognized words.
Reading order does not matter, so two-column pages are scored fairly. Illegible lines count as no text.
With --baseline the verdict says whether the new run is better (see docs/DECISIONS.md D-022).
"""
import argparse, difflib, json, re, sys, unicodedata

def words(text):
    text = unicodedata.normalize("NFC", text).lower()
    return [w for w in re.split(r"[^0-9a-zäöüß]+", text) if w]

def score(ref_lines, rec_lines):
    ref = [w for l in ref_lines for w in words(l)]
    rec = [w for l in rec_lines for w in words(l)]
    unused = list(rec)
    credit, misses = 0.0, []
    rest = []
    for w in ref:
        if w in unused:
            unused.remove(w); credit += 1
        else:
            rest.append(w)
    for w in rest:
        best, ratio = None, 0.0
        for c in unused:
            r = difflib.SequenceMatcher(None, w, c).ratio()
            if r > ratio: best, ratio = c, r
        if best is not None and ratio >= 0.75:
            unused.remove(best); credit += ratio
        else:
            misses.append(w)
    recall = credit / len(ref) if ref else 1.0
    precision = credit / len(rec) if rec else (1.0 if not ref else 0.0)
    f1 = 2 * recall * precision / (recall + precision) if recall + precision else 0.0
    return dict(recall=recall, precision=precision, f1=f1, missing=misses, extra=unused)

# Letters that never occur in German notes (Greek, Cyrillic, Latin beyond Latin-1 except Œ Š Ž ẞ, …).
FOREIGN = re.compile(r"[\u0100-\u0151\u0154-\u015f\u0162-\u017c\u017f-\u024f\u0370-\u052f\u0590-\u06ff"
                     r"\u1e00-\u1e9d\u1e9f-\u1eff\u3040-\u30ff\u4e00-\u9fff\uac00-\ud7af]")

def load(path):
    with open(path) as f: return json.load(f)

def stats(page):
    lines = page["lines"]
    return dict(
        lines=len(lines),
        illegible=sum(l["status"] == "illegible" for l in lines),
        uncertain=sum(l["status"] == "uncertain" for l in lines),
        foreign=sum(bool(FOREIGN.search(l["text"])) and l["status"] == "confident" for l in lines),
    )

def evaluate(run, ref):
    result = {}
    for page in run["pages"]:
        key = str(page["page"])
        entry = stats(page)
        if key in ref.get("pages", {}):
            entry.update(score(ref["pages"][key], [l["text"] for l in page["lines"]]))
        result[key] = entry
    return result

def total(evaluated):
    scored = [e for e in evaluated.values() if "f1" in e]
    return dict(
        f1=sum(e["f1"] for e in scored) / len(scored) if scored else 0,
        recall=sum(e["recall"] for e in scored) / len(scored) if scored else 0,
        precision=sum(e["precision"] for e in scored) / len(scored) if scored else 0,
        lines=sum(e["lines"] for e in evaluated.values()),
        illegible=sum(e["illegible"] for e in evaluated.values()),
        uncertain=sum(e["uncertain"] for e in evaluated.values()),
        foreign=sum(e["foreign"] for e in evaluated.values()),
    )

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run"); parser.add_argument("--ref", required=True); parser.add_argument("--baseline")
    parser.add_argument("--details", action="store_true", help="fehlende und überzählige Wörter je Seite")
    args = parser.parse_args()
    run, ref = load(args.run), load(args.ref)
    new = evaluate(run, ref)
    old = evaluate(load(args.baseline), ref) if args.baseline else None

    print(f"Lauf: {args.run} ({run['seconds']:.1f} s)")
    for key in sorted(new, key=int):
        e = new[key]
        line = f"S.{key:>3}: {e['lines']:3} Zeilen, {e['illegible']:2} unleserlich, {e['uncertain']:2} unsicher"
        if "f1" in e:
            line += f" | F1 {e['f1']:.3f} (R {e['recall']:.3f}, P {e['precision']:.3f})"
            if old and "f1" in old.get(key, {}):
                line += f"  Δ {e['f1'] - old[key]['f1']:+.3f}"
        print(line)
        if args.details and "f1" in e:
            print("       fehlt:", " ".join(e["missing"]) or "-")
            print("       extra:", " ".join(e["extra"]) or "-")
    t = total(new)
    print(f"Gesamt: F1 {t['f1']:.4f} (R {t['recall']:.4f}, P {t['precision']:.4f}), {t['lines']} Zeilen, "
          f"{t['illegible']} unleserlich, {t['uncertain']} unsicher, {t['foreign']} mit fremden Zeichen ohne Markierung")
    if old is None:
        return
    o = total(old)
    print(f"Vorher: F1 {o['f1']:.4f} (R {o['recall']:.4f}, P {o['precision']:.4f}), {o['lines']} Zeilen, "
          f"{o['illegible']} unleserlich, {o['uncertain']} unsicher, {o['foreign']} mit fremden Zeichen ohne Markierung")
    worse = [k for k in new if "f1" in new[k] and k in old and "f1" in old[k] and new[k]["f1"] < old[k]["f1"] - 0.005]
    # Pages without reference: show text that disappeared, so regressions there are visible too.
    base_pages = {str(p["page"]): p for p in load(args.baseline)["pages"]}
    for page in run["pages"]:
        key = str(page["page"])
        if key in ref.get("pages", {}) or key not in base_pages: continue
        before = [l["text"] for l in base_pages[key]["lines"] if l["text"]]
        after = [l["text"] for l in page["lines"] if l["text"]]
        lost = score(before, after)
        if lost["recall"] < 0.97:
            print(f"S.{key:>3} ohne Referenz: {100 * (1 - lost['recall']):.1f} % des alten Texts fehlt: {' '.join(lost['missing'][:15])}")
    # Better: no reference page worse, F1 not lower, no more unflagged foreign letters, and a real gain in F1,
    # or the same F1 with fewer unflagged foreign letters, illegible marks or uncertain marks (false alarms).
    same = abs(t["f1"] - o["f1"]) <= 0.001
    gain = t["f1"] > o["f1"] + 0.001 or (same and (t["foreign"] < o["foreign"] or t["illegible"] < o["illegible"]
                                                  or t["uncertain"] < o["uncertain"]))
    better = gain and not worse and t["f1"] >= o["f1"] - 0.001 and t["foreign"] <= o["foreign"]
    print("Urteil:", "BESSER – übernehmen" if better else "NICHT BESSER – verwerfen",
          f"(schlechtere Seiten: {', '.join(worse)})" if worse else "")

if __name__ == "__main__":
    main()
