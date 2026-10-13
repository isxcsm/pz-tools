"""Resolves merge conflicts in the translation JSON files by taking the keys of both sides.

Packages add their own keys (by prefix) to the same files, so a conflict there is two lists of new keys next to each
other. This writes every key from both sides (ours first, then theirs that are new), drops a key that one side
removed and the other left alone, and fails if one key has two different texts or was changed on one side and
removed on the other.

    py tools/merge_translations.py        (during a merge; then git add the files and commit)
"""
import json
import subprocess
import sys

GIT = r'C:\Program Files\Git\cmd\git.exe'


def stage(n, path):
    out = subprocess.run([GIT, 'show', ':%d:%s' % (n, path)], capture_output=True, encoding='utf-8')
    return json.loads(out.stdout) if out.returncode == 0 else {}


def main():
    out = subprocess.run([GIT, 'diff', '--name-only', '--diff-filter=U'], capture_output=True, encoding='utf-8')
    paths = [p for p in out.stdout.split() if p.endswith('.json') and '/Translate/' in p]
    failed = False
    for path in paths:
        base, ours, theirs = stage(1, path), stage(2, path), stage(3, path)
        merged = dict(ours)
        for key, text in theirs.items():
            if key in merged and merged[key] != text:
                if merged[key] == base.get(key):
                    merged[key] = text
                elif text != base.get(key):
                    print('both sides changed %s in %s' % (key, path))
                    failed = True
            elif key not in merged and key in base:
                if text != base[key]:
                    print('%s was removed on our side and changed on theirs in %s' % (key, path))
                    failed = True
            else:
                merged[key] = text
        # a key one side removed and the other left as it was is gone
        for key, text in base.items():
            if key in merged and key not in theirs:
                if merged[key] == text:
                    del merged[key]
                else:
                    print('%s was changed on our side and removed on theirs in %s' % (key, path))
                    failed = True
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(merged, f, ensure_ascii=False, indent=4)
            f.write('\n')
        print('merged %s: %d + %d -> %d keys' % (path, len(ours), len(theirs), len(merged)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
