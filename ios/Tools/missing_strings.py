#!/usr/bin/env python3
"""Lists UI string literals that have no entry in a language's Localizable.strings.
Usage: python3 Tools/missing_strings.py [lang]   (default: every language)
Checks literals passed to Text, Button, Label, Toggle, NavigationLink, Section,
navigationTitle, ToolPage(title/subtitle), L(...), LS(...), accessibilityLabel.
Interpolations become %@ / %lld, as SwiftUI keys do."""
import re, sys, os, glob
root = os.path.join(os.path.dirname(__file__), '..', 'DocumentScanner')
calls = r'(?:Text|Button|Label|Toggle|NavigationLink|Section|navigationTitle|Picker|L|LS|SectionLabel\(text:|title:|subtitle:|accessibilityLabel|TextField|ContentUnavailableView|LabeledContent|Link)'
lit = re.compile(calls + r'\(\s*"((?:[^"\\]|\\.)*)"')
lit2 = re.compile(r'(?:title|subtitle|text|label|message|detail):\s*"((?:[^"\\]|\\.)*)"')
def keyify(s):
    s = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', s)
    return s.replace('\\n', '\n').replace('\\"', '"')
def load(lang):
    p = os.path.join(root, f'{lang}.lproj', 'Localizable.strings')
    txt = open(p, encoding='utf-8').read()
    keys = set(m.replace('\\n', '\n').replace('\\"', '"') for m in re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', txt, re.M))
    return keys
def norm(k): return re.sub(r'%(?:lld|ld|d|@|\.\d+f|f)', '%@', k)
skip = re.compile(r'^[\W\d_]*$|^[a-z0-9-]+(-[a-z0-9]+)+$|^[a-z]+\.[a-z.]+$|^%@$')
langs = sys.argv[1:] or ['ko']
found = {}
for f in glob.glob(os.path.join(root, '*.swift')):
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        if 'accessibilityIdentifier' in line and line.count('"') == 2: continue
        for rx in (lit, lit2):
            for m in rx.finditer(line):
                k = keyify(m.group(1))
                if skip.match(k) or not re.search(r'[A-Za-z]{2}', k): continue
                found.setdefault(k, f'{os.path.basename(f)}:{n}')
for lang in langs:
    keys = {norm(k) for k in load(lang)}
    miss = sorted((v, k) for k, v in found.items() if norm(k) not in keys)
    print(f'== {lang}: {len(miss)} missing')
    for where, k in miss: print(f'{where}\t{k!r}')
