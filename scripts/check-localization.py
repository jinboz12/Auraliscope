#!/usr/bin/env python3
"""Checks the string tables against the code and the language policy in Sources/Auraliscope/Localizer.swift.

1. Every key the code passes to L("…") or LKey("…") exists in every Localizable.strings table.
2. No table keeps a key the code no longer uses.
3. The English table maps each key to itself (the English text is the key).
4. Each translation keeps the key's format specifiers (%@, %d…) and its trailing ellipsis.
5. Terms that are never translated (units, abbreviations, True Peak, standards, product names, and labels quoted
   as the meter prints them) appear unchanged in every translation.
6. Terms with an established translation use it consistently (Stereo → 立体声 / 스테레오, Momentary → 瞬时 / 순간…).
7. A key made only of never-translated terms is an error: write it as a literal instead of calling L().
8. A SwiftUI view that calls L( observes Localizer.shared, so a language switch redraws it (text inside a
   StatusMessage closure is exempt: it is rendered when shown).
"""
import glob
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = sorted(glob.glob(str(ROOT / "Sources/Auraliscope/*.swift")))
TABLES = sorted(glob.glob(str(ROOT / "Resources/Localization/*.lproj/Localizable.strings")))

# Kept in English in every language, matched case-sensitively as whole words. Longer terms first.
PROTECTED = [
    # Standards, products and technologies
    "ITU-R BS.1770-5", "BS.1770", "EBU Tech 3342", "EBU R128", "ATSC A/85", "Dolby Atmos", "Apple Music",
    "Spotify", "YouTube", "Tidal", "Netflix", "EDM", "Core Audio", "AUHAL", "HAL", "AudioUnit", "Accelerate",
    "vDSP", "Metal", "SwiftUI", "AppKit", "C11", "MIT", "AudioSpectrogram", "OSStatus", "Float32 PCM", "FFT",
    "Auraliscope", "macOS", "Mac", "DAW",
    # Units, abbreviations and True Peak
    "True Peak", "LUFS", "LKFS", "LU", "dBFS", "dBTP", "dB", "RMS", "VU", "kHz", "Hz",
    "LFE", "L/R", "Ls", "Rs", "L", "R", "C",
    # Labels quoted exactly as the meter window prints them
    "SHORT-TERM LOUDNESS", "TRUE PEAK", "TARGET", "CEILING", "SPECTROGRAM", "SPECTRUM", "WAVEFORM", "SOUNDSTAGE",
    "LOUDNESS", "MOMENTARY", "INTEGRATED", "RANGE", "PEAK", "CORRELATION", "AUTO", "ON TARGET",
]
# Terms with an established translation, used for them everywhere outside the meter window.
GLOSSARY = {
    "Multi Channel": ("多声道", "멀티채널"), "Stereo": ("立体声", "스테레오"), "Mono": ("单声道", "모노"),
    "Auto": ("自动", "자동"), "Momentary": ("瞬时", "순간"), "Short-term": ("短期", "단기"),
    "Integrated": ("积分", "통합"), "Range": ("响度范围", "레인지"), "Peak": ("峰值", "피크"),
    "Spectrogram": ("声谱图", "스펙트로그램"), "Spectrum": ("频谱", "스펙트럼"), "Waveform": ("波形", "파형"),
    "Soundstage": ("声场", "사운드스테이지"), "Front": ("前置", "프런트"), "Surround": ("环绕", "서라운드"),
    "Height": ("顶部", "하이트"),
}
# Word edges are ASCII-only: Korean particles and CJK characters may follow a term directly ("Stereo와").
def whole_word(term):
    return re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(term) + r"(?![A-Za-z0-9_-])")


TERM_PATTERNS = [(term, whole_word(term)) for term in PROTECTED]
GLOSSARY_PATTERNS = [(term, whole_word(term), translations) for term, translations in GLOSSARY.items()]
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:l|ll|h|hh|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSaAp])")
KEY_CALL = re.compile(r'\b(?:L|LKey)\("((?:[^"\\]|\\.)*)"')

failures = []


def fail(message):
    failures.append(message)


def swift_unescape(text):
    return text.replace('\\"', '"').replace("\\\\", "\\")


def load(table):
    xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", table], capture_output=True, check=True).stdout
    return plistlib.loads(xml)


def specifiers(text):
    """Format specifiers in argument order, e.g. ['@', 'd']; positional ones are placed by their index."""
    found = [(m.group(1), m.group(2)) for m in SPECIFIER.finditer(text.replace("%%", ""))]
    if any(index for index, _ in found):
        ordered = sorted(found, key=lambda item: int(item[0] or 0))
        return [kind.replace("i", "d") for _, kind in ordered]
    return [kind.replace("i", "d") for _, kind in found]


def terms_in(text):
    """Protected terms in text, longest first, each occurrence masked so 'True Peak' does not also count 'Peak'."""
    found = []
    for term, pattern in TERM_PATTERNS:
        if pattern.search(text):
            found.append(term)
            text = pattern.sub(" ", text)
    return found, text


# Keys used by the code.
used = set()
for path in SOURCES:
    source = Path(path).read_text(encoding="utf-8")
    for match in KEY_CALL.finditer(source):
        key = swift_unescape(match.group(1))
        if "\\(" in key:
            fail(f"{Path(path).name}: interpolation inside a localization key: {key!r}")
        used.add(key)

tables = {Path(table).parent.stem: load(table) for table in TABLES}
if set(tables) != {"en", "zh-Hans", "ko"}:
    fail(f"expected en, zh-Hans and ko tables, found {sorted(tables)}")

for language, table in tables.items():
    missing = sorted(used - table.keys())
    unused = sorted(table.keys() - used)
    if missing:
        fail(f"{language}: missing {len(missing)} key(s): {missing}")
    if unused:
        fail(f"{language}: {len(unused)} unused key(s): {unused}")
    for key, value in table.items():
        if language == "en" and value != key:
            fail(f"en: value differs from its key: {key!r} → {value!r}")
        if specifiers(value) != specifiers(key):
            fail(f"{language}: format specifiers differ: {key!r} → {value!r}")
        if key.endswith("…") != value.endswith("…"):
            fail(f"{language}: trailing ellipsis differs: {key!r} → {value!r}")
        terms, rest = terms_in(key)
        for term in terms:
            if not dict(TERM_PATTERNS)[term].search(value):
                fail(f"{language}: {term!r} must stay in English: {key!r} → {value!r}")
        if language != "en":
            for term, pattern, translations in GLOSSARY_PATTERNS:
                wanted = translations[0 if language == "zh-Hans" else 1]
                if pattern.search(rest) and wanted not in value:
                    fail(f"{language}: {term!r} should read {wanted!r}: {key!r} → {value!r}")
                rest = pattern.sub(" ", rest)

for key in sorted(used):
    _, rest = terms_in(key)
    if not re.sub(r"%(?:\d+\$)?[@dDiuUxXoOfeEgGcCsSaAp]|[\W\d_]", "", rest):
        fail(f"only instrument vocabulary, write it as a literal instead of L(): {key!r}")

# Views that call L( in their body must observe Localizer.shared.
VIEW = re.compile(r"\bstruct\s+(\w+)(?:<[^>{]*>)?\s*:\s*[^{]*\b(View|ToolbarContent|NSViewRepresentable|App)\b[^{]*\{")
for path in SOURCES:
    source = Path(path).read_text(encoding="utf-8")
    for match in VIEW.finditer(source):
        depth, end = 0, match.end() - 1
        for end in range(match.end() - 1, len(source)):
            depth += {"{": 1, "}": -1}.get(source[end], 0)
            if depth == 0:
                break
        # A StatusMessage closure is rendered on demand by whoever shows it, so it needs no observation here.
        body = re.sub(r"StatusMessage \{[^}]*\}", "", source[match.end():end])
        if re.search(r"\bL\(", body) and "Localizer.shared" not in body:
            fail(f"{Path(path).name}: {match.group(1)} calls L( but does not observe Localizer.shared")

if failures:
    print("\n".join(f"FAILED {message}" for message in failures), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(used)} keys in en, zh-Hans and ko; placeholders, instrument terms and view observation checked")
