#!/usr/bin/env python3
"""Scores a word-review-bench run: marks of the word-level review (D-044) and the reading suggestions of the
production provider (VisionWordCandidateProvider, D-046).

    swift run -c release --package-path Packages/StudyHelperCore word-review-bench measure \\
        LocalSamples/<file>.pdf LocalSamples/bench/<lines>.json LocalSamples/<file>.reference.json \\
        LocalSamples/bench/<run>.json [--rerank] [--terms none|suggested|reference]
    scripts/score-word-review.py LocalSamples/bench/<run>.json [--list]

Ground truth: a recognized word is wrong if it differs from its aligned reference word (case-insensitive,
punctuation trimmed) or has no counterpart. Structural tokens (numbers, single characters) are never marked by
WordReview and are left out of the marking numbers. Suggestion hits compare case-insensitively.
"""
import argparse, json, unicodedata, re
from collections import defaultdict

TRIM = re.compile(r"^[\W_]+|[\W_]+$", re.UNICODE)

def norm(s):
    return TRIM.sub("", unicodedata.normalize("NFC", s or "").lower())

def core(s):
    return TRIM.sub("", unicodedata.normalize("NFC", s or ""))

def lev(a, b):
    if not a: return len(b)
    if not b: return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j - 1] + (ca != cb), prev[j] + 1, cur[j - 1] + 1))
        prev = cur
    return prev[-1]

def ratio(a, b):
    a, b = norm(a), norm(b)
    n = max(len(a), len(b))
    return lev(a, b) / n if n else 0.0

def prf(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    return p, r

def without_original(cands, word):
    out, seen = [], set()
    for c in cands:
        c = core(c)
        if not c or c == core(word) or norm(c) in seen: continue
        seen.add(norm(c)); out.append(c)
    return out

def strategies(t):
    s = t["suggestions"]; w = t["core"]
    return {
        "local (WordReview)": without_original(s["local"], w),
        "local + Referenz-Fachbegriffe": without_original(s["localTerms"], w),
        "Provider (App)": without_original(s.get("provider", []), w),
    }

def median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    d = json.load(open(a.run))
    T = d["tokens"]
    words = [t for t in T if not t["structural"]]
    print(f"Wörter: {len(T)} (ohne Zahlen/Einzelzeichen: {len(words)}), falsch: {sum(t['wrong'] for t in words)}"
          f" (+{sum(t['wrong'] for t in T if t['structural'])} Zahlen/Einzelzeichen), nur Groß/klein falsch: "
          f"{sum(t.get('caseOnly', False) for t in T)}, Modell: {d['model']}, Fachbegriffe im Provider: "
          f"{d.get('termMode')}")
    print(f"Vorgeschlagene Fachbegriffe (TermSuggestions): {', '.join(d.get('suggestedTerms', [])) or '–'}")
    for p in d["pages"]:
        print(f"  S.{p['page']}: fehlende Referenzwörter {len(p['missingReferenceWords'])}: {' '.join(p['missingReferenceWords'])}")

    # ---------- marking ----------
    def marker_table(name, pred):
        tp = fp = fn = 0
        per = defaultdict(lambda: [0, 0, 0])
        for t in words:
            m, w = pred(t), t["wrong"]
            k = per[t["page"]]
            if m and w: tp += 1; k[0] += 1
            elif m: fp += 1; k[1] += 1
            elif w: fn += 1; k[2] += 1
        p, r = prf(tp, fp, fn)
        pages = "  ".join(f"S{pg}:{v[0]}/{v[0]+v[1]}/{v[0]+v[2]}" for pg, v in sorted(per.items()))
        print(f"| {name:<38} | {tp+fp:>4} | {tp:>3} | {fp:>3} | {fn:>3} | {p:5.2f} | {r:5.2f} | {pages}")

    print("\nMarkierung (TP/markiert/falsch je Seite)")
    print("| Regel | markiert | TP | FP | FN | Präz. | Recall |")
    spell = lambda t: t.get("markedPlain") is not None
    spellT = lambda t: t.get("markedTerms") is not None
    spellS = lambda t: t.get("markedSuggested") is not None
    marker_table("WordReview (keine Fachbegriffe)", spell)
    marker_table("WordReview + Termvorschläge übernommen", spellS)
    marker_table("WordReview + Referenz-Fachbegriffe", spellT)

    if a.list:
        print("\nFalsch positiv (ohne Fachbegriffe):", ", ".join(t["text"] for t in words if spell(t) and not t["wrong"]))
        print("Falsch positiv (Termvorschläge):", ", ".join(t["text"] for t in words if spellS(t) and not t["wrong"]))
        print("Übersehen (Termvorschläge):", ", ".join(f"{t['text']}→{t.get('ref')}" for t in words if t["wrong"] and not spellS(t)))

    # ---------- suggestions ----------
    wrong = [t for t in words if t["wrong"] and t.get("ref") and t.get("suggestions")]
    print(f"\nVorschläge für {len(wrong)} falsche Wörter mit Referenz (Treffer = Referenzwort, ohne Groß/klein)")
    print("| Strategie | Top-1 | Top-5 | leer | Ø Länge |")
    names = list(strategies(wrong[0]).keys()) if wrong else []
    for n in names:
        h1 = h5 = empty = length = 0
        for t in wrong:
            c = strategies(t)[n]
            ref = norm(t["ref"])
            h1 += bool(c) and norm(c[0]) == ref
            h5 += any(norm(x) == ref for x in c[:5])
            empty += not c
            length += len(c)
        print(f"| {n:<34} | {h1:>3} ({h1/len(wrong):4.0%}) | {h5:>3} ({h5/len(wrong):4.0%}) | {empty:>3} | {length/len(wrong):4.1f} |")

    sug = [t for t in words if t.get("suggestions")]
    secs = [t["suggestions"]["seconds"] for t in sug]
    if secs:
        print(f"  Provider-Latenz je Wort: Median {median(secs):.2f} s, max {max(secs):.2f} s "
              f"(erster Aufruf mit Öffnen des PDFs: {d.get('firstCallSeconds') or 0:.2f} s)")
    rl = [t["suggestions"]["rerankSeconds"] for t in sug if t["suggestions"].get("rerankSeconds")]
    if rl:
        print(f"  Modell-Antwort: Median {median(rl):.2f} s, max {max(rl):.2f} s, über 2 s: {sum(x > 2 for x in rl)}/{len(rl)}")
    moved = sum(any("model" in s for s in t["suggestions"].get("providerSources", [])) for t in sug)
    if d["model"]:
        print(f"  Modell hat die Reihenfolge bei {moved}/{len(sug)} Wörtern geändert")

    # ---------- unrelated suggestions ----------
    marked = [t for t in sug if t.get("markedPlain") or t.get("markedSuggested") or t["wrong"]]
    print(f"\n'Fremde' Vorschläge (Abstand > 0,5 zum erkannten Wort UND zur Referenz) bei {len(marked)} markierten/falschen Wörtern")
    print("| Strategie | Top-1 fremd: Zeile ≤2 Wörter | Zeile >2 | Anteil fremd in Top-5: Zeile ≤2 | gesamt |")
    def unrelated(c, t):
        return ratio(c, t["core"]) > 0.5 and (not t.get("ref") or ratio(c, t["ref"]) > 0.5)
    for n in names:
        cells = []
        for group in [lambda t: t["lineTokenCount"] <= 2, lambda t: t["lineTokenCount"] > 2]:
            g = [t for t in marked if group(t)]
            withs = [t for t in g if strategies(t)[n]]
            u = sum(unrelated(strategies(t)[n][0], t) for t in withs)
            cells.append(f"{u}/{len(withs)}")
        def share(group):
            pairs = [(c, t) for t in marked if group(t) for c in strategies(t)[n][:5]]
            return sum(unrelated(c, t) for c, t in pairs) / len(pairs) if pairs else 0
        print(f"| {n:<34} | {cells[0]:>7} | {cells[1]:>7} | {share(lambda t: t['lineTokenCount'] <= 2):4.0%} | "
              f"{share(lambda t: True):4.0%} |")

    if a.list:
        print("\nJe falsches Wort: erkannt → Referenz | Provider (Quellen) | local")
        for t in wrong:
            s = t["suggestions"]
            prov = [f"{c}[{','.join(x[:1] for x in src)}]" for c, src in zip(s["provider"][:4], s["providerSources"][:4])]
            hit = "✓" if s["provider"] and norm(s["provider"][0]) == norm(t["ref"]) else ("5" if any(norm(x) == norm(t["ref"]) for x in s["provider"][:5]) else "✗")
            print(f"  {hit} S{t['page']} {t['core']} → {core(t['ref'])} [Z.{t['lineTokenCount']}W] | {' '.join(prov)} | {s['local'][:3]}")
        print("\nFremde Provider-Vorschläge in Top-5:")
        for t in marked:
            bad = [c for c in t["suggestions"]["provider"][:5] if unrelated(c, t)]
            if bad:
                print(f"  {t['core']} (ref {core(t.get('ref'))}, Zeile {t['lineTokenCount']} W.) → {bad}")

if __name__ == "__main__":
    main()
