#!/usr/bin/env python3
"""Takes a returned table of translations into Localizable.xcstrings.

The table is the one the translator hands back: a JSON list of
    {"source": "<Chinese text as it stood in the Swift source, with \\(…) and \\n>", "translations": {"en": "…", …}}
Entries are matched to the catalog's keys by their Chinese text (arguments and line breaks made comparable), so the
table does not need to know the keys. In a translation every \\(expression) becomes the placeholder of the argument
it stood for in the source, with its position when there are several, so the order may differ from the Chinese.

Nothing is translated here. What cannot be matched is listed and left out; keys without a translation stay empty
(strings.py --check names them).

usage: import_strings.py returned.json [--dry]
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "Localizable.xcstrings")
PLACE = re.compile(r'%(?:(\d+)\$)?(lld|@)')


def pieces(text):
    """A Swift literal's text split into plain parts and the expressions inside \\( … ), brackets balanced."""
    out, plain, i = [], "", 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append(("text", plain)); plain = ""
            out.append(("arg", text[i + 2:j - 1].strip()))
            i = j
        else:
            plain += text[i]; i += 1
    out.append(("text", plain))
    return out


def plain(text):
    return text.replace("\\n", "\n").replace('\\"', '"')


def shape(parts):
    """What is compared: the text with every argument reduced to a mark."""
    return "".join("\u0001" if kind == "arg" else plain(value) for kind, value in parts).strip()


def main():
    table = json.load(open(sys.argv[1], encoding="utf-8"))
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    source = catalog["sourceLanguage"]
    by_shape = {}
    for key, item in catalog["strings"].items():
        value = item["localizations"][source]["stringUnit"]["value"]
        kinds = [m.group(2) for m in PLACE.finditer(value)]
        by_shape.setdefault(PLACE.sub("\u0001", value).replace("%%", "%").strip(), []).append((key, kinds))

    unmatched, odd, used, count = [], [], set(), 0
    for entry in table:
        parts = pieces(entry["source"])
        keys = by_shape.get(shape(parts))
        if not keys:
            unmatched.append(entry["source"]); continue
        order = []                      # the expressions in the order the Chinese has them = the order of the arguments
        for kind, value in parts:
            if kind == "arg" and value not in order: order.append(value)
        for key, kinds in keys:
            used.add(key)
            for language, text in entry["translations"].items():
                if not isinstance(text, str) or not text.strip():
                    continue
                result, seen = "", []
                for kind, value in pieces(text.replace("\n", "\\n")):
                    if kind == "text":
                        result += plain(value).replace("%", "%%") if kinds else plain(value)
                    elif value in order:
                        n = order.index(value); seen.append(n)
                        result += f"%{n + 1}${kinds[n]}" if len(kinds) > 1 else f"%{kinds[n]}"
                    else:
                        result = None; break
                if result is None or sorted(set(seen)) != list(range(len(kinds))):
                    odd.append((key, language, text)); continue
                catalog["strings"][key]["localizations"][language] = {"stringUnit": {"state": "translated", "value": result}}
                count += 1
    for key in catalog["strings"]:
        catalog["strings"][key]["localizations"] = dict(sorted(catalog["strings"][key]["localizations"].items()))

    print(f"{count} translations taken for {len(used)} of {len(catalog['strings'])} keys")
    if unmatched:
        print(f"\n{len(unmatched)} entries of the table match no key (the Chinese has changed since, or the text is gone):")
        for text in unmatched: print("  ", text[:110])
    if odd:
        print(f"\n{len(odd)} translations left out, their arguments do not match the Chinese:")
        for key, language, text in odd: print("  ", key, language, text[:90])
    missing = sorted(set(catalog["strings"]) - used)
    if missing:
        print(f"\n{len(missing)} keys the table has nothing for:")
        for key in missing: print("  ", key, "=", catalog["strings"][key]["localizations"][source]["stringUnit"]["value"][:60].replace("\n", " / "))
    if "--dry" not in sys.argv:
        with open(CATALOG, "w", encoding="utf-8") as out:
            json.dump(catalog, out, ensure_ascii=False, indent=2, separators=(",", " : "))
            out.write("\n")


if __name__ == "__main__":
    main()
