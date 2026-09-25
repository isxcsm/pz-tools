#!/usr/bin/env python3
"""Compare fresh repository metadata layouts; never open a user's repository.

Example: python scripts/measure-compact-repository.py --baseline-ref 6f2023c
Both layouts are populated with identical synthetic metadata then VACUUMed.
This measures metadata space, not backups, compression speed or game performance.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
import pathlib
import re
import sqlite3
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA_PATH = 'src/PzTools.Backup.Storage/Repository/RepositorySchema.cs'
NOW_TEXT = '2026-09-25T00:00:00.1234567+00:00'
NOW_TICKS = 639258912001234567


def schema_sql(source: str) -> str:
    section = source.split('internal static class RepositoryMigrationRunner')[0]
    statements = re.findall(r'"""\s*\n(.*?)\n\s*"""', section, re.S)
    if not statements:
        raise ValueError('No production schema SQL found')
    return '\n'.join(statements)


def make_database(path: pathlib.Path, sql: str, count: int, compact: bool, dedup: bool) -> dict:
    with closing(sqlite3.connect(path)) as db:
        db.execute('PRAGMA page_size=4096')
        db.execute('PRAGMA foreign_keys=ON')
        db.executescript(sql)
        db.execute('INSERT INTO sources VALUES(1,?,?,?)', ('Sandbox/Test', '/synthetic/save', NOW_TEXT))
        db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,1)')
        db.execute("INSERT INTO runs VALUES(1,1,'Succeeded',?,?,NULL)", (NOW_TEXT, NOW_TEXT))
        db.execute('INSERT INTO revisions(source_id,revision,run_index,created_utc) VALUES(1,1,1,?)', (NOW_TEXT,))
        encode_id = lambda n: uuid.UUID(int=n).bytes_le if compact else str(uuid.UUID(int=n))
        db.execute("INSERT INTO packs VALUES(?,?,1,1,'Committed',1,?)", (encode_id(1), 'packs/synthetic.pzpack', NOW_TEXT))
        parent = (f'{1:016X}:{1:032X}').encode()
        if compact:
            parent = bytes.fromhex(parent.decode().replace(':', ''))
        objects, entries = [], []
        for n in range(1, count + 1):
            digest = hashlib.sha256(str(n).encode()).digest()
            checksum = digest if dedup else digest[:8]  # widths only; not a real pack fixture
            fingerprint = digest[:16] if compact else digest
            object_id = encode_id(n + 1)
            objects.append((object_id, encode_id(1), n * 80, 64, 128,
                            (3 if dedup else 2) if compact else ('Sha256' if dedup else 'XxHash64'),
                            checksum, 2 if compact else 'Brotli', 0,
                            *([fingerprint] if compact else ['Sha256', fingerprint])))
            identity = f'{1:016X}:{n+1:032X}'
            identity = bytes.fromhex(identity.replace(':', '')) if compact else identity.encode()
            name = f'map/chunk_{n:05d}.bin'
            time = NOW_TICKS if compact else NOW_TEXT
            entries.append((1, name.upper(), name, 1, None, 'File', 0, 128,
                            time, time, 32, identity, parent, object_id))
        db.executemany('INSERT INTO stored_objects VALUES(' + ','.join('?' * len(objects[0])) + ')', objects)
        db.executemany('INSERT INTO entry_versions VALUES(' + ','.join('?' * 14) + ')', entries)
        db.commit()
        assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
        assert not db.execute('PRAGMA foreign_key_check').fetchall()
        assert db.execute('SELECT count(*),sum(byte_length) FROM entry_versions').fetchone() == (count, count * 128)
        plans = []
        if compact:
            assert db.execute('SELECT length(file_id),length(parent_file_id),typeof(modified_utc) FROM entry_versions LIMIT 1').fetchone() == (24, 24, 'integer')
            assert db.execute('SELECT length(object_id),length(pack_id),length(content_hash) FROM stored_objects LIMIT 1').fetchone() == (16, 16, 16)
            for statement in ["UPDATE stored_objects SET content_hash=zeroblob(32)",
                              "UPDATE entry_versions SET file_id=zeroblob(49)",
                              "UPDATE stored_objects SET checksum_algorithm=999"]:
                try:
                    db.execute(statement)
                except sqlite3.IntegrityError:
                    db.rollback()
                else:
                    raise AssertionError('Invalid compact representation accepted: ' + statement)
            plans = [r[3] for r in db.execute('EXPLAIN QUERY PLAN SELECT object_id FROM stored_objects WHERE original_length=128 AND checksum_algorithm=3 AND checksum=?', (bytes(32),))]
            assert any('ix_stored_objects_dedup' in p for p in plans), plans
        db.execute('VACUUM')
        pages = db.execute('PRAGMA page_count').fetchone()[0]
        free = db.execute('PRAGMA freelist_count').fetchone()[0]
        return {'bytes': pages * 4096, 'free_pages': free, 'dedup_lookup_plan': plans}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='6f2023c')
    parser.add_argument('--entries', type=int, default=22000)
    args = parser.parse_args()
    if not 1 <= args.entries <= 1_000_000:
        parser.error('--entries must be between 1 and 1,000,000')
    old = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:{SCHEMA_PATH}'], cwd=ROOT, text=True)
    new = (ROOT / SCHEMA_PATH).read_text()
    results = {'sqlite_version': sqlite3.sqlite_version, 'entries': args.entries, 'profiles': {}}
    with tempfile.TemporaryDirectory(prefix='pz-compact-layout-') as temp:
        for dedup in (False, True):
            profile = 'sha256-dedup' if dedup else 'xxhash64-default'
            before = make_database(pathlib.Path(temp) / f'{profile}-old.db', schema_sql(old), args.entries, False, dedup)
            after = make_database(pathlib.Path(temp) / f'{profile}-new.db', schema_sql(new), args.entries, True, dedup)
            results['profiles'][profile] = {'before': before, 'after': after,
                'reduction_percent': round((1 - after['bytes'] / before['bytes']) * 100, 2)}
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
