#!/usr/bin/env python3
"""Offline checks for English documentation and the single root user guide.

Standard library only. Supported Markdown syntax and limitations are documented in
`docs/contributing/documentation-maintenance.md`. This checks structure, not prose quality.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import html
import os
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
import unicodedata
from urllib.parse import unquote, urlsplit

# Topics the guide must keep. Other sections may be added freely; each must still explain something.
GUIDE_SECTIONS = (
    'features', 'getting-started', 'backups-and-retention', 'game-saving',
    'restore-and-archives', 'character-recovery', 'performance-recording',
    'compatibility-and-limits', 'troubleshooting', 'building', 'technical-documentation',
    'license',
)
GUIDE_REFERENCES = (
    'docs/README.md', 'docs/development.md', 'docs/configuration.md',
    'docs/repository-housekeeping.md', 'docs/game-bridge.md', 'docs/character-recovery.md',
)
GUIDE_FACT_TOKENS = (
    'PzTools.App.exe', '.NET 10', 'Windows x64', 'Java 25', 'global.json',
)


class DocumentationError(ValueError):
    pass


def blank(text: str) -> str:
    return re.sub(r'[^\n]', ' ', text)


def without_code(text: str, *, inline: bool = True) -> str:
    """Mask examples but retain line numbers for diagnostics."""
    lines = []
    fence: tuple[str, int] | None = None
    for line in text.splitlines(keepends=True):
        match = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line.rstrip('\r\n'))
        if fence is not None:
            lines.append(blank(line))
            if match and match[1][0] == fence[0] and len(match[1]) >= fence[1] and not match[2].strip():
                fence = None
        elif match:
            fence = (match[1][0], len(match[1]))
            lines.append(blank(line))
        else:
            lines.append(line)
    if fence is not None:
        raise DocumentationError('Unclosed fenced code block')
    result = ''.join(lines)
    result = re.sub(r'<!--.*?-->', lambda m: blank(m[0]), result, flags=re.S)
    if inline:
        # Closing delimiter must be the same length, not part of a longer run.
        result = re.sub(r'(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)',
                        lambda m: blank(m[0]), result, flags=re.S)
    return result


def slug(heading: str) -> str:
    text = re.sub(r'!?\[([^\]]+)\]\([^)]*\)', r'\1', heading)
    text = re.sub(r'<[^>]+>', '', text)
    text = html.unescape(text).replace('`', '').replace('*', '').strip().lower()
    # Underscore is valid in an ID, but paired emphasis markers are not displayed.
    text = re.sub(r'(?<!\w)_([^_]+)_(?!\w)', r'\1', text)
    return ''.join(c for c in text if unicodedata.category(c)[0] in 'LNM'
                   or c in ' _-').replace(' ', '-')


def heading_ids(text: str) -> set[str]:
    source = without_code(text, inline=False)
    ids: set[str] = set()
    lines = source.splitlines()
    for index, line in enumerate(lines):
        atx = re.match(r'^ {0,3}#{1,6}\s+(.+?)\s*$', line)
        heading = None
        if atx:
            heading = re.sub(r'\s+#+\s*$', '', atx[1])
        elif index > 0 and re.fullmatch(r' {0,3}(?:=+|-+)\s*', line):
            prior = lines[index-1].strip()
            if prior and not re.match(r'^(?:[>|]|[-*+]\s|\d+\.\s|<)', prior):
                heading = prior
        if heading is not None:
            base = slug(heading)
            candidate, number = base, 0
            while candidate in ids:
                number += 1
                candidate = f'{base}-{number}'
            ids.add(candidate)
    return ids


@dataclass(frozen=True)
class Link:
    target: str
    line: int


class HtmlLinks(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[Link] = []
        self.anchors: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        for attr in ('href', 'src'):
            if attr in values:
                self.links.append(Link(values[attr] or '', self.getpos()[0]))
        name = values.get('id') or (values.get('name') if tag == 'a' else None)
        if name:
            if name in self.anchors:
                raise DocumentationError(f'Duplicate explicit anchor: {name}')
            self.anchors.add(name)


def balanced_end(text: str, start: int, left: str, right: str) -> int | None:
    depth, i = 1, start+1
    quoted: str | None = None
    while i < len(text):
        char = text[i]
        if char == '\\':
            i += 2
            continue
        if quoted:
            if char == quoted:
                quoted = None
        elif left == '(' and char in '\"\'' and i > start+1 and text[i-1].isspace():
            quoted = char
        elif char == left:
            depth += 1
        elif char == right:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def destination(value: str) -> str:
    value = value.strip()
    if value.startswith('<'):
        end = value.find('>')
        if end < 0:
            raise DocumentationError('Unclosed angle-bracket link destination')
        value = value[1:end]
    else:
        match = re.match(r'(?:\\.|[^\s])+', value)
        value = match[0] if match else ''
    return html.unescape(re.sub(r'\\([\\()`<>\[\] ])', r'\1', value))


def label_key(label: str) -> str:
    return ' '.join(label.split()).casefold()


def markdown_links(text: str) -> list[Link]:
    definitions: dict[str, str] = {}
    pattern = r'(?m)^ {0,3}\[([^\]\n]+)\]:[ \t]*(.+)$'
    for match in re.finditer(pattern, text):
        key = label_key(match[1])
        if key in definitions:
            raise DocumentationError(f'Duplicate reference definition: {match[1]}')
        definitions[key] = destination(match[2])
    text = re.sub(pattern, lambda m: blank(m[0]), text)
    result: list[Link] = []
    i = 0
    while i < len(text):
        if text[i] == '\\':
            i += 2
            continue
        if text[i] != '[':
            i += 1
            continue
        end = balanced_end(text, i, '[', ']')
        if end is None:
            i += 1
            continue
        label, after, target = text[i+1:end], end+1, None
        if after < len(text) and text[after] == '(':
            closing = balanced_end(text, after, '(', ')')
            if closing is None:
                raise DocumentationError(f'Unclosed link at line {text.count(chr(10), 0, i)+1}')
            target = destination(text[after+1:closing])
            after = closing+1
        elif after < len(text) and text[after] == '[':
            closing = balanced_end(text, after, '[', ']')
            if closing is None:
                raise DocumentationError('Unclosed reference link')
            key = label_key(text[after+1:closing] or label)
            if key not in definitions:
                raise DocumentationError(f'Undefined reference: {key}')
            target = definitions[key]
            after = closing+1
        elif label_key(label) in definitions:
            target = definitions[label_key(label)]
        if target is not None:
            result.append(Link(target, text.count('\n', 0, i)+1))
        i = after
    return result


@dataclass
class Document:
    text: str
    links: list[Link]
    anchors: set[str]
    explicit: set[str]

    @classmethod
    def parse(cls, text: str) -> Document:
        visible = without_code(text)
        parser = HtmlLinks()
        parser.feed(visible)
        return cls(text, parser.links + markdown_links(visible),
                   heading_ids(text) | parser.anchors, parser.anchors)


def exact_path(root: Path, target: Path) -> bool:
    """Also detect case mistakes on Windows, where Path.exists() alone cannot."""
    if not target.exists():
        return False
    current = root
    for part in target.relative_to(root).parts:
        if part not in {child.name for child in current.iterdir()}:
            return False
        current /= part
    return True


def validate_link(root: Path, source: Path, link: Link,
                  documents: dict[Path, Document]) -> Path | None:
    href = link.target
    if not href:
        raise DocumentationError('Empty link destination')
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme not in ('https', 'http', 'mailto') or (parsed.scheme != 'mailto' and not parsed.netloc):
            raise DocumentationError(f'Unsupported or invalid external link: {href}')
        return None
    path = unquote(parsed.path)
    if '\\' in path:
        raise DocumentationError(f'Use forward slashes in repository links: {href}')
    candidate = ((root / path.lstrip('/')) if path.startswith('/') else source.parent / path) if path else source
    # abspath normalizes .. without correcting the user's case on Windows.
    # Resolve separately for symlink containment, then check the authored casing.
    authored = Path(os.path.abspath(candidate))
    target = authored.resolve()
    if not target.is_relative_to(root):
        raise DocumentationError(f'Link escapes repository: {href}')
    if not authored.is_relative_to(root) or not exact_path(root, authored):
        raise DocumentationError(f'Missing target or wrong case: {href}')
    anchor = unquote(parsed.fragment)
    if anchor:
        if target.suffix.lower() == '.md':
            if target not in documents:
                documents[target] = Document.parse(target.read_text(encoding='utf-8-sig'))
            doc = documents[target]
            if anchor not in doc.anchors:
                raise DocumentationError(f'Missing section: {href}')
        elif target.is_file() and re.fullmatch(r'L\d+(?:-L\d+)?', anchor):
            lines = [int(n) for n in re.findall(r'\d+', anchor)]
            count = len(target.read_text(encoding='utf-8-sig').splitlines())
            if any(n < 1 or n > count for n in lines) or lines != sorted(lines):
                raise DocumentationError(f'Invalid source line range: {href}')
        else:
            raise DocumentationError(f'Unsupported section target: {href}')
    return target


def check_guide(root: Path, documents: dict[Path, Document],
                local_targets: dict[Path, set[Path]]) -> None:
    path = root / 'README.md'
    doc = documents[path]
    missing = set(GUIDE_SECTIONS) - doc.explicit
    if missing:
        raise DocumentationError(f'README.md: missing guide topics: {sorted(missing)}')
    # Require a heading plus authored explanation, not a section containing only a link. Any number
    # of sections: adding one is ordinary editing, not something the checker has to be told about.
    blocks = re.split(r'<a\s+id="[^"]+"\s*></a>', doc.text)
    headings = [b for b in blocks if re.search(r'(?m)^## ', b)]
    for block in headings:
        body = re.sub(r'(?m)^##[^\n]*\n', '', block).strip()
        if not body or not re.search(r'\w', re.sub(r'\[[^\]]*\]\([^)]*\)', '', body)):
            raise DocumentationError('README.md: guide section has no explanation')
    absent = {root / p for p in GUIDE_REFERENCES} - local_targets[path]
    if absent:
        raise DocumentationError('README.md: missing direct reference: '
                                 + ', '.join(str(p.relative_to(root)) for p in sorted(absent)))
    prose = re.sub(r'[-‐‑–]', ' ', doc.text)
    for token in GUIDE_FACT_TOKENS:
        if re.sub(r'[-‐‑–]', ' ', token) not in prose:
            raise DocumentationError(f'README.md: missing technical instruction: {token}')
    for url in ('https://github.com/isxcsm/pz-tools/releases',
                'https://github.com/isxcsm/pz-tools/issues',
                'https://dotnet.microsoft.com/en-us/download/dotnet/10.0'):
        if url not in {link.target for link in doc.links}:
            raise DocumentationError(f'README.md: missing runtime, download or support link: {url}')


def check(root: Path) -> dict[str, int]:
    root = root.resolve()
    parallel_guides = sorted(root.glob('docs/*/README.md'))
    if parallel_guides:
        raise DocumentationError('Localized README guides are not supported; use the English root README: '
                                 + ', '.join(str(p.relative_to(root)) for p in parallel_guides))
    paths = sorted({root/'README.md', root/'THIRD_PARTY_NOTICES.md', *root.glob('docs/**/*.md')})
    docs: dict[Path, Document] = {}
    targets: dict[Path, set[Path]] = {}
    externals: set[str] = set()
    local_count = 0
    for path in paths:
        if not path.is_file():
            raise DocumentationError(f'Missing document: {path.relative_to(root)}')
        docs[path] = Document.parse(path.read_text(encoding='utf-8-sig'))
    for path in paths:
        targets[path] = set()
        for link in docs[path].links:
            try:
                target = validate_link(root, path, link, docs)
            except ValueError as error:
                raise DocumentationError(f'{path.relative_to(root)}:{link.line}: {error}') from error
            if target is None:
                externals.add(link.target)
            else:
                targets[path].add(target)
                local_count += 1
    check_guide(root, docs, targets)
    index = root/'docs/README.md'
    if index not in docs:
        raise DocumentationError('Missing documentation index')
    references = set(root.glob('docs/*.md')) - {index}
    missing = (references | {root/'README.md', root/'THIRD_PARTY_NOTICES.md'}) - targets[index]
    if missing:
        raise DocumentationError('Documents missing from index: ' + ', '.join(str(p.relative_to(root)) for p in sorted(missing)))
    for path in references:
        if index not in targets[path]:
            raise DocumentationError(f'{path.relative_to(root)}: missing index backlink')
    return {'documents': len(paths), 'guides': 1, 'topics_per_guide': len(GUIDE_SECTIONS),
            'local_links': local_count, 'external_urls_not_fetched': len(externals),
            'indexed_reference_documents': len(references)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        result = check(args.root)
    except (OSError, UnicodeError, ValueError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    print('PASS: ' + ', '.join(f'{key}={value}' for key, value in result.items()))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
