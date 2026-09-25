"""Apply only the exact reviewed documentation delta on its expected file contents."""
import base64
import hashlib
import json
import lzma
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
PARTS = Path(__file__).resolve().parent
EXPECTED = '42750790d2b37d5e843e897c50f3c441c7286745bc4ae94732da4314d5fac6fe'
SCRIPTS = {'scripts/check-documentation.py', 'scripts/test-documentation-checker.py', 'scripts/test-readme-links.ps1'}

def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()

def allowed(name):
    path = PurePosixPath(name)
    return not path.is_absolute() and '..' not in path.parts and '\\' not in name and (
        name == 'README.md' or name in SCRIPTS or (name.startswith('docs/') and name.endswith('.md')))

parts = sorted(PARTS.glob('part-*.txt'))
assert [p.name for p in parts] == [f'part-{i:02d}.txt' for i in range(1, 11)]
encoded = ''.join(p.read_text(encoding='ascii') for p in parts)
assert len(encoded) == 96124
raw = lzma.decompress(base64.b64decode(encoded, validate=True), memlimit=256 * 1024 * 1024)
assert len(raw) == 250432 and hashlib.sha256(raw).hexdigest() == EXPECTED
changes = json.loads(raw)
assert len(changes) == 50
prepared = {}
for name, change in changes.items():
    assert allowed(name), name
    path = ROOT / name
    assert path.resolve().is_relative_to(ROOT.resolve())
    if change['before'] is None:
        assert not path.exists(), f'New file already exists: {name}'
        old = ''
    else:
        old = path.read_text(encoding='utf-8')
        assert digest(old) == change['before'], f'Baseline mismatch: {name}'
    lines = old.splitlines(keepends=True)
    previous_end = 0
    for start, end, replacement in change['edits']:
        assert isinstance(start, int) and isinstance(end, int) and isinstance(replacement, str)
        assert previous_end <= start <= end <= len(lines), name
        previous_end = end
    for start, end, replacement in reversed(change['edits']):
        lines[start:end] = [replacement]
    text = ''.join(lines)
    assert digest(text) == change['after'], f'Result mismatch: {name}'
    prepared[path] = text
# No writes until every baseline and result has been verified.
for path, text in prepared.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')
print(f'Applied {len(prepared)} exact documentation/checker files; no product files changed.')
