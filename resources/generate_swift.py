#!/usr/bin/env python3
"""Compile resources/ into Swift source (D-131, like D-126 does for the platform catalog).

Writes Packages/PhotoFrameStorage/Sources/PhotoFrameStorage/BuiltInWatermarkData.swift:
the two manifests as JSON strings, and every logo / icon file. SVG files are stored as text
(tabs and newlines turned into spaces), PNG files as base64. Run after changing anything in resources/:

    python3 resources/generate_swift.py

A test in PhotoFrameStorage fails when the generated file is out of date.
"""
import base64
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, '..', 'Packages', 'PhotoFrameStorage', 'Sources', 'PhotoFrameStorage', 'BuiltInWatermarkData.swift')


def raw(s):
    """Swift raw string literal that cannot be closed early by the content."""
    hashes = '#'
    while ('"' + hashes) in s:
        hashes += '#'
    return f'{hashes}"{s}"{hashes}'


def swift_source():
    brands = json.load(open(os.path.join(ROOT, 'cameras', 'brands.json')))
    films = json.load(open(os.path.join(ROOT, 'films', 'films.json')))
    files = []  # (key, kind, literal)
    for b in brands:
        for rel in b['files'].values():
            files.append(('cameras/' + rel, os.path.join(ROOT, 'cameras', rel)))
    for f in films:
        files.append(('films/' + f['icon'], os.path.join(ROOT, 'films', f['icon'])))
    cases = []
    for key, path in sorted(files):
        data = open(path, 'rb').read()
        if path.endswith('.svg'):
            text = ''.join(' ' if ord(ch) < 0x20 else ch for ch in data.decode('utf-8'))  # tabs / newlines → spaces
            cases.append(f'        case {raw(key)}: return Data({raw(text)}.utf8)')
        elif path.endswith('.png'):
            cases.append(f'        case {raw(key)}: return Data(base64Encoded: {raw(base64.b64encode(data).decode())})')
        else:
            sys.exit(f'unsupported file type: {path}')
    out = [
        '// 由 resources/generate_swift.py 从 resources/ 生成，不要手改（D-131）。',
        '// swiftlint:disable all',
        'import Foundation',
        '',
        'extension BuiltInWatermarks {',
        '    /// resources/cameras/brands.json',
        f'    static let brandsJSON = {raw(json.dumps(brands, ensure_ascii=False, separators=(",", ":")))}',
        '',
        '    /// resources/films/films.json',
        f'    static let filmsJSON = {raw(json.dumps(films, ensure_ascii=False, separators=(",", ":")))}',
        '',
        '    /// 内置素材文件，键是相对 resources/ 的路径。',
        '    public static func fileData(_ path: String) -> Data? {',
        '        switch path {',
        *cases,
        '        default: return nil',
        '        }',
        '    }',
        '',
        f'    public static let filePaths: [String] = [{", ".join(raw(k) for k, _ in sorted(files))}]',
        '}',
        '',
    ]
    return '\n'.join(out)


if __name__ == '__main__':
    src = swift_source()
    if '--check' in sys.argv:
        sys.exit(0 if open(OUT).read() == src else 'BuiltInWatermarkData.swift is out of date; run resources/generate_swift.py')
    open(OUT, 'w').write(src)
    print(f'wrote {os.path.relpath(OUT)} ({len(src)} bytes)')
