# Brings Folio's String Catalogs up to date with the code, keeping every
# translation already in them. New strings get their drafts from drafts.py,
# marked "needs review" for a native speaker; strings the code no longer uses
# are dropped.
#
# Build the Debug app first, so the compiler has extracted the strings, then:
#
#   python3 -I Tools/Localization/update_catalogs.py <DerivedData folder>
#
# It lists any new string without a draft and exits with status 1, so drafts
# can be added to drafts.py before running it again.
import collections, glob, json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(os.path.dirname(here))
sys.path.insert(0, here)
import drafts  # noqa: E402

LANGS = {"fr": "fr", "es": "es", "de": "de", "zh": "zh-Hans"}

# Strings that are only formatting, examples or identifiers.
NO_TRANSLATION = {"", "%@", "%lld", "%@, %@", "%@\n%@", "%@ · %@", "MATH1131", "{subject}/{year}/{type}", "Privacy_Reminders", "Privacy_Calendars", "Folio"}

SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaA]')

CATALOGS = {
    "Folio": os.path.join(repo, "Folio/Localizable.xcstrings"),
    "FolioKit": os.path.join(repo, "FolioKit/Sources/FolioKit/Resources/Localizable.xcstrings"),
}


def specifiers(key):
    return [m.group(0) for m in SPEC.finditer(key)]


def canon(key, typed):
    """The key with its format specifiers as {} (or {@}, {d}, {f} when typed)."""
    def rep(m):
        s = m.group(0)
        if not typed:
            return '{}'
        return '{@}' if s.endswith('@') else ('{f}' if s[-1] in 'fFeEgG' else '{d}')
    return SPEC.sub(rep, key)


def fill(template, specs, key):
    """Puts the key's format specifiers into a translation's {} or {n}."""
    positional = re.findall(r'\{(\d+)\}', template)
    sequential = template.count('{}')
    if positional and sequential:
        raise ValueError(f"mixes {{}} and {{n}}: {template!r} for {key!r}")
    if positional:
        out = re.sub(r'\{(\d+)\}', lambda m: '%' + f'{m.group(1)}$' + specs[int(m.group(1)) - 1][1:], template)
    else:
        if sequential > len(specs):
            raise ValueError(f"too many {{}} in {template!r} for {key!r}")
        parts = template.split('{}')
        out = parts[0]
        for i, part in enumerate(parts[1:]):
            out += specs[i] + part
    # A literal % in a translation would break the format.
    if '%' in SPEC.sub('', out).replace('%%', ''):
        raise ValueError(f"stray % in {out!r}")
    return out


def unit(value, state):
    return {"stringUnit": {"state": state, "value": value}}


def localizations(key, entry):
    specs = specifiers(key)
    result = {}
    if entry["kind"] == "plain":
        for short, lang in LANGS.items():
            result[lang] = unit(fill(entry[short], specs, key), "needs_review")
        return result
    if len(specs) != 1:
        raise ValueError(f"plural with {len(specs)} numbers: {key!r}")
    one, other = entry["en"]
    result["en"] = {"variations": {"plural": {
        "one": unit(fill(one, specs, key), "translated"),
        "other": unit(fill(other, specs, key), "translated"),
    }}}
    for short, lang in LANGS.items():
        forms = entry[short]
        if isinstance(forms, str):
            variations = {"other": unit(fill(forms, specs, key), "needs_review")}
        else:
            variations = {
                "one": unit(fill(forms[0], specs, key), "needs_review"),
                "other": unit(fill(forms[1], specs, key), "needs_review"),
            }
        result[lang] = {"variations": {"plural": variations}}
    return result


def extracted(derived):
    """Every string the compiler found, by target, with its comment."""
    keys = {"Folio": collections.OrderedDict(), "FolioKit": collections.OrderedDict()}
    pattern = os.path.join(derived, 'Build/Intermediates.noindex/*/Debug/**/*.stringsdata')
    for path in sorted(glob.glob(pattern, recursive=True)):
        target = 'FolioKit' if 'FolioKit.build' in path else 'Folio'
        data = json.load(open(path))
        for table, entries in data.get('tables', {}).items():
            if table != 'Localizable':
                continue
            for e in entries:
                comment = e.get('comment', '')
                if e['key'] not in keys[target] or (comment and not keys[target][e['key']]):
                    keys[target][e['key']] = comment
    return keys


def updated(old, found):
    strings = collections.OrderedDict()
    missing, added = [], []
    for key, comment in sorted(found.items(), key=lambda kv: kv[0].lower()):
        previous = old.get(key)
        if previous is not None and (previous.get("localizations") or previous.get("shouldTranslate") is False):
            entry = dict(previous)
            if comment:
                entry["comment"] = comment
            entry.pop("extractionState", None)
            strings[key] = entry
            continue
        entry = {}
        if comment:
            entry["comment"] = comment
        if key in NO_TRANSLATION or not re.search(r'[A-Za-z]', SPEC.sub('', key)):
            entry["shouldTranslate"] = False
        else:
            draft = drafts.ENTRIES.get(canon(key, True)) or drafts.ENTRIES.get(canon(key, False))
            if draft is None:
                missing.append(key)
            else:
                entry["localizations"] = localizations(key, draft)
                added.append(key)
        strings[key] = entry
    removed = [key for key in old if key not in found]
    return strings, missing, added, removed


def main():
    if len(sys.argv) != 2:
        print(__doc__ or "usage: update_catalogs.py <DerivedData>")
        return 64
    found = extracted(sys.argv[1])
    all_missing = []
    results = []
    # Work everything out first, so a bad draft leaves every catalog as it was.
    for target, path in CATALOGS.items():
        catalog = json.load(open(path))
        strings, missing, added, removed = updated(catalog["strings"], found[target])
        catalog["strings"] = strings
        results.append((path, catalog))
        print(f"{target}: {len(strings)} strings, {len(added)} new with drafts, {len(missing)} without a draft, {len(removed)} no longer used")
        for key in removed:
            print("  removed:", repr(key))
        all_missing += missing
    for path, catalog in results:
        with open(path, 'w') as f:
            json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
            f.write('\n')
    for key in all_missing:
        print("  needs a draft:", repr(canon(key, False)))
    return 1 if all_missing else 0


if __name__ == "__main__":
    sys.exit(main())
