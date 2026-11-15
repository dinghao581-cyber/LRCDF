#!/usr/bin/env python3
"""Brings Localizable.xcstrings in line with Sources/LRCDF/Strings.swift.

Strings.swift holds every text of the app in Simplified Chinese (the source language), each with a stable key and a
comment for the translator. This script writes those into the String Catalog: new keys are added, comments and the
Chinese text are updated, translations into other languages are kept, and a translation whose Chinese text has since
changed is marked "needs_review". Keys that no longer exist are removed.

usage: strings.py                 update Localizable.xcstrings (build.sh does this)
       strings.py --check         exit 1 if the catalog is not up to date or a language is incomplete
       strings.py --pseudo FILE   write a copy with a made-up language "en" whose texts are 40 % wider (short ones more),
                                  for checking that nothing clips (PSEUDO=1 ./build.sh, then
                                  open -a LRCDF --args -AppleLanguages "(en)")
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "Sources/LRCDF/Strings.swift")
CATALOG = os.path.join(HERE, "Localizable.xcstrings")
LANGUAGE = "zh-Hans"

ENTRY = re.compile(r'String\(localized: "([^"]+)", defaultValue: "((?:[^"\\]|\\.)*)", comment: "((?:[^"\\]|\\.)*)"\)')
FUNC = re.compile(r'static func \w+\(([^)]*)\) -> String')


def unescape(text):
    return text.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')


def entries():
    found, types = [], {}
    for line in open(SOURCE, encoding="utf-8"):
        signature = FUNC.search(line)
        if signature:      # the arguments of the text on the next line: name -> printf specifier
            types = {}
            for position, part in enumerate(signature.group(1).split(","), 1):
                name, kind = part.replace("_ ", "").split(":")
                types[name.strip()] = (position, "lld" if kind.strip() == "Int" else "@")
        match = ENTRY.search(line)
        if not match:
            continue
        key, text, comment = match.group(1), match.group(2), unescape(match.group(3))
        several = len(types) > 1

        def specifier(m):
            position, kind = types[m.group(1)]
            return f"%{position}${kind}" if several else f"%{kind}"
        if types:          # a text with arguments is a format: a plain % has to be doubled
            text = re.sub(r'\\\((\w+)\)', specifier, text.replace("%", "%%"))
        text = unescape(text)
        found.append((key, text, comment))
        types = {}
    return found


def build(old):
    strings = {}
    for key, text, comment in entries():
        before = old.get("strings", {}).get(key, {})
        places = dict(before.get("localizations", {}))
        was = places.get(LANGUAGE, {}).get("stringUnit", {}).get("value")
        if was is not None and was != text:      # the Chinese changed: the other languages have to be looked at again
            for language, place in places.items():
                if language != LANGUAGE and "stringUnit" in place:
                    place["stringUnit"]["state"] = "needs_review"
        places[LANGUAGE] = {"stringUnit": {"state": "translated", "value": text}}
        strings[key] = {"comment": comment, "extractionState": "manual", "localizations": dict(sorted(places.items()))}
    return {"sourceLanguage": LANGUAGE, "strings": dict(sorted(strings.items())), "version": "1.0"}


def pseudo(catalog):
    for item in catalog["strings"].values():
        text = item["localizations"][LANGUAGE]["stringUnit"]["value"]
        plain = re.sub(r'%(\d+\$)?(lld|@)', '', text)
        wide = sum(1.0 if ord(c) > 0x2E80 else 0.55 for c in plain)
        # 40 % wider; a word or two of Chinese becomes far longer than that in most languages, so short texts get more
        extra = max(round(wide * 0.4 / 0.55), 6 if wide <= 4 else 0)
        item["localizations"]["en"] = {"stringUnit": {"state": "translated", "value": text + "é" * extra}}
    return catalog


def dump(catalog, path):
    with open(path, "w", encoding="utf-8") as out:
        json.dump(catalog, out, ensure_ascii=False, indent=2, separators=(",", " : "))
        out.write("\n")


if __name__ == "__main__":
    old = json.load(open(CATALOG, encoding="utf-8")) if os.path.exists(CATALOG) else {}
    new = build(old)
    if "--pseudo" in sys.argv:
        dump(pseudo(new), sys.argv[sys.argv.index("--pseudo") + 1])
    elif "--check" in sys.argv:
        problems = [] if new == old else ["Localizable.xcstrings is not up to date with Strings.swift: run app/strings.py"]
        languages = {l for item in new["strings"].values() for l in item["localizations"]}
        for language in sorted(languages - {LANGUAGE}):
            for key, item in new["strings"].items():
                state = item["localizations"].get(language, {}).get("stringUnit", {}).get("state")
                if state != "translated" and "variations" not in item["localizations"].get(language, {}):
                    problems.append(f"{language}: {key} is {state or 'missing'}")
        print("\n".join(problems) or f"ok: {len(new['strings'])} texts, languages: {', '.join(sorted(languages))}")
        sys.exit(1 if problems else 0)
    else:
        dump(new, CATALOG)
        print(f"{len(new['strings'])} texts in Localizable.xcstrings")
