#!/usr/bin/env python3
"""Measure only catalog SQL on isolated synthetic metadata, never a live repository.

Run from a checkout containing the baseline commit:
python scripts/measure-catalog-performance.py --baseline-ref 2f3ce6f
Both queries read the same fresh schema-2 database. Cached summaries are seeded
independently, all returned rows must match, and both queries are warmed first.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'src/PzTools.Backup.Storage/Repository/'
NOW = '2026-09-25T00:00:00+00:00'
TICKS = 639258912000000000


def raw_sql(source: str) -> list[str]:
    return re.findall(r'"""\s*\n(.*?)\n\s*"""', source, re.S)


def seed(db: sqlite3.Connection, files: int, revisions: int, changes: int) -> int:
    db.execute('PRAGMA foreign_keys=ON')
    schema = (ROOT / (REPOSITORY + 'RepositorySchema.cs')).read_text()
    db.executescript(raw_sql(schema.split('internal static class RepositoryMigrationRunner')[0])[0])
    db.execute('INSERT INTO sources VALUES(1,?,?,?)', ('Sandbox/Synthetic', '/synthetic/never-opened', NOW))
    db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,?)', (revisions,))
    # One synthetic object is sufficient: we benchmark metadata lookup, not pack reads.
    pack = (1).to_bytes(16, 'little')
    object_id = (2).to_bytes(16, 'little')
    names = ['players.db'] + [f'map/chunk_{i:05d}.bin' for i in range(1, files)]
    sizes = [1024 + i % 8192 for i in range(files)]
    total = sum(sizes)
    rows = 0
    for revision in range(1, revisions + 1):
        db.execute("INSERT INTO runs VALUES(?,1,'Succeeded',?,?,NULL)", (revision, NOW, NOW))
        changed = range(files) if revision == 1 else [(revision * changes + i) % files for i in range(changes)]
        if revision > 1:
            for i in changed:
                total -= sizes[i]
                sizes[i] = 1024 + (i * 17 + revision * 31) % 8192
                total += sizes[i]
        db.execute('INSERT INTO revisions(source_id,revision,run_index,created_utc,logical_size,file_count) '
                   'VALUES(1,?,?,?,?,?)', (revision, revision, NOW, total, files))
        if revision == 1:
            db.execute("INSERT INTO packs VALUES(?,?,1,1,'Committed',1,?)", (pack, 'packs/synthetic.pzpack', NOW))
            db.execute('INSERT INTO stored_objects VALUES(?,?,0,1,1,3,?,1,0,?)',
                       (object_id, pack, bytes(32), bytes(16)))
        entries = []
        for i in changed:
            if revision > 1:
                db.execute('UPDATE entry_versions SET valid_to_revision=? '
                           'WHERE source_id=1 AND path_key=? AND valid_to_revision IS NULL',
                           (revision, names[i].upper()))
            entries.append((1, names[i].upper(), names[i], revision, None, 'File', 0,
                            sizes[i], TICKS + revision, TICKS + revision, 32,
                            (i + 1).to_bytes(24, 'big'), bytes(24), object_id))
        db.executemany('INSERT INTO entry_versions VALUES(' + ','.join('?' * 14) + ')', entries)
        rows += len(entries)
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    return rows


def measure(db: sqlite3.Connection, sql: str, parameters: dict, repetitions: int) -> tuple[list, dict]:
    rows = db.execute(sql, parameters).fetchall()  # warm up
    samples = []
    for _ in range(repetitions):
        start = time.perf_counter()
        actual = db.execute(sql, parameters).fetchall()
        samples.append((time.perf_counter() - start) * 1000)
        assert actual == rows
    return rows, {'median_ms': round(statistics.median(samples), 4),
                  'samples_ms': [round(value, 4) for value in samples],
                  'plan': [row[3] for row in db.execute('EXPLAIN QUERY PLAN ' + sql, parameters)]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='2f3ce6f')
    parser.add_argument('--files', type=int, default=10000)
    parser.add_argument('--revisions', type=int, default=100)
    parser.add_argument('--changes', type=int, default=100)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    if not (1 <= args.files <= 100000 and 1 <= args.revisions <= 1000
            and 0 <= args.changes <= args.files and 1 <= args.repetitions <= 20):
        parser.error('Invalid fixture size or repetition count')
    before = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + REPOSITORY +
                                      'RepositoryDatabase.Read.cs'], cwd=ROOT, text=True)
    old_sql = next(sql for sql in raw_sql(before) if 'SUM(CASE' in sql and 'FROM sources AS source' in sql)
    new_sql = raw_sql((ROOT / (REPOSITORY + 'RepositoryDatabase.Summaries.cs')).read_text())[0]
    results = {'sqlite_version': sqlite3.sqlite_version, 'files': args.files,
               'revisions': args.revisions, 'changes_per_revision': args.changes,
               'query_sha256': {name: hashlib.sha256(sql.encode()).hexdigest()
                                for name, sql in [('before', old_sql), ('after', new_sql)]}, 'profiles': {}}
    with tempfile.TemporaryDirectory(prefix='pz-catalog-sql-') as temp:
        with closing(sqlite3.connect(Path(temp) / 'fixture.db')) as db:
            results['entry_versions'] = seed(db, args.files, args.revisions, args.changes)
            for key in (None, 'PLAYERS.DB'):
                parameters = {'metadataPathKey': key}
                old_rows, old = measure(db, old_sql, parameters, args.repetitions)
                new_rows, new = measure(db, new_sql, parameters, args.repetitions)
                assert new_rows == old_rows, 'Catalog results changed'
                assert not any('SCAN entry' in line for line in new['plan']), new['plan']
                results['profiles']['no-metadata' if key is None else 'players-metadata'] = {
                    'before': old, 'after': new, 'equal_rows': len(new_rows),
                    'median_ratio': round(old['median_ms'] / new['median_ms'], 2)}
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
