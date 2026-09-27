#!/usr/bin/env python3
"""Execute production housekeeping SQL against isolated SQLite fixtures.
This supplements, not replaces, dotnet/Windows integration tests.
"""
import re
import sqlite3
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODE = (ROOT / 'src/PzTools.Backup.Storage/Repository/RepositoryDatabase.Housekeeping.cs').read_text()
SQL = [textwrap.dedent(s).strip() for s in re.findall(r'"""(.*?)"""', CODE, re.S)]
DUE, DUE_SOURCES, HISTORY_SELECT, PRUNE_RUNS, ACTIVE = SQL
ENTRY_CODE = (ROOT / 'src/PzTools.Backup.Storage/Repository/RepositoryDatabase.EntryCollection.cs').read_text()
ENTRY_WINDOW = textwrap.dedent(re.findall(r'"""(.*?)"""', ENTRY_CODE, re.S)[0]).strip()
CUTOFF = '2026-01-01T00:00:00.0000000+00:00'
OLD = '2000-01-01T00:00:00.0000000+00:00'
NEW = '2099-01-01T00:00:00.0000000+00:00'
# Same columns/relationships consumed by housekeeping, including real FK directions.
SCHEMA = '''
PRAGMA foreign_keys=ON;
CREATE TABLE repository_info(singleton INTEGER PRIMARY KEY, next_run_index INTEGER NOT NULL) STRICT;
INSERT INTO repository_info VALUES(1,10000);
CREATE TABLE sources(source_id INTEGER PRIMARY KEY) STRICT;
INSERT INTO sources VALUES(1),(2);
CREATE TABLE source_state(source_id INTEGER PRIMARY KEY REFERENCES sources(source_id), current_revision INTEGER NOT NULL) STRICT;
INSERT INTO source_state VALUES(1,4),(2,4);
CREATE TABLE runs(run_index INTEGER PRIMARY KEY, source_id INTEGER REFERENCES sources(source_id), status TEXT NOT NULL, started_utc TEXT, completed_utc TEXT) STRICT;
CREATE TABLE revisions(source_id INTEGER NOT NULL REFERENCES sources(source_id), revision INTEGER NOT NULL, run_index INTEGER NOT NULL UNIQUE REFERENCES runs(run_index), state TEXT NOT NULL, deleted_utc TEXT, PRIMARY KEY(source_id,revision)) STRICT;
CREATE TABLE packs(pack_id TEXT PRIMARY KEY, created_run_index INTEGER NOT NULL REFERENCES runs(run_index)) STRICT;
CREATE TABLE stored_objects(object_id TEXT PRIMARY KEY, pack_id TEXT REFERENCES packs(pack_id)) STRICT;
CREATE TABLE entry_versions(source_id INTEGER NOT NULL, path_key TEXT NOT NULL, valid_from_revision INTEGER NOT NULL, valid_to_revision INTEGER, tombstone INTEGER NOT NULL, object_id TEXT REFERENCES stored_objects(object_id), PRIMARY KEY(source_id,path_key,valid_from_revision), FOREIGN KEY(source_id,valid_from_revision) REFERENCES revisions(source_id,revision), CHECK(valid_to_revision IS NULL OR valid_to_revision>valid_from_revision)) STRICT;
CREATE TABLE workflow_runs(run_index INTEGER PRIMARY KEY, pipeline TEXT NOT NULL, source_id INTEGER REFERENCES sources(source_id), status TEXT NOT NULL, completed_utc TEXT) STRICT;
CREATE TABLE workflow_stages(run_index INTEGER REFERENCES workflow_runs(run_index), producer TEXT, status TEXT NOT NULL, completed_utc TEXT, PRIMARY KEY(run_index,producer)) STRICT;
'''


def execute_many(db, sql, params):
    for statement in sql.split(';'):
        if statement.strip():
            db.execute(statement, params)


def prune_entries(db, source, limit, after=None):
    sql = ENTRY_WINDOW.replace('/*cursor*/', 'WHERE entry.rowid>$after' if after is not None else '')
    rows = db.execute(sql, {'sourceId':source, 'limit':limit, 'after':after}).fetchall()
    removed = 0
    for rowid, eligible in rows:
        if eligible:
            removed += db.execute('DELETE FROM entry_versions WHERE rowid=?', (rowid,)).rowcount
    return (rows[-1][0] if len(rows)==limit else None), len(rows), removed


def prune_history(db, keep=1, limit=1000):
    params = {'keep': keep, 'cutoff': CUTOFF, 'limit': limit}
    with db:
        execute_many(db, HISTORY_SELECT, params)
        stages = db.execute('DELETE FROM workflow_stages WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)').rowcount
        workflows = db.execute('DELETE FROM workflow_runs WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)').rowcount
        runs = db.execute(PRUNE_RUNS, params).rowcount
    # Production opens a fresh non-pooled connection each time.
    db.execute('DROP TABLE housekeeping_recent')
    db.execute('DROP TABLE housekeeping_workflows')
    return runs, workflows, stages


class HousekeepingSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript(SCHEMA)

    def tearDown(self):
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
        self.assertEqual('ok', self.db.execute('PRAGMA integrity_check').fetchone()[0])
        self.db.close()

    def seed_history(self, count=12):
        for i in range(1, count+1):
            self.db.execute('INSERT INTO runs VALUES(?,1,\'Succeeded\',?,?)', (i, OLD, OLD))
            self.db.execute('INSERT INTO workflow_runs VALUES(?,\'backup\',1,\'Succeeded\',?)', (i, OLD))
            self.db.execute('INSERT INTO workflow_stages VALUES(?,\'worker\',\'Succeeded\',?)', (i, OLD))
        self.db.commit()

    def seed_versions(self, states=('Active','Deleted','Deleted','Deleted'), source=1):
        for rev, state in enumerate(states, 1):
            index = source*100+rev
            self.db.execute('INSERT INTO runs VALUES(?, ?,\'Succeeded\',?,?)', (index, source, OLD, OLD))
            self.db.execute('INSERT INTO revisions VALUES(?,?,?,?,?)', (source, rev, index, state, OLD if state == 'Deleted' else None))
            self.db.execute('INSERT INTO entry_versions VALUES(?,\'A\',?,?,?,NULL)', (source, rev, rev+1 if rev<4 else None, 1 if rev==4 else 0))
        self.db.commit()

    def snapshot(self, source, revision):
        return self.db.execute('SELECT * FROM entry_versions WHERE source_id=? AND valid_from_revision<=? AND (valid_to_revision IS NULL OR valid_to_revision>?) ORDER BY path_key', (source,revision,revision)).fetchall()

    def test_small_old_deletion_becomes_due(self):
        self.seed_versions()
        self.assertEqual(1, self.db.execute(DUE, {'sourceId':1,'batch':20,'cutoff':CUTOFF}).fetchone()[0])

    def test_recent_deletions_remain_batched(self):
        self.seed_versions()
        self.db.execute('UPDATE revisions SET deleted_utc=? WHERE state=\'Deleted\'', (NEW,))
        self.assertEqual(0, self.db.execute(DUE, {'sourceId':1,'batch':20,'cutoff':CUTOFF}).fetchone()[0])
        self.assertEqual(1, self.db.execute(DUE, {'sourceId':1,'batch':2,'cutoff':CUTOFF}).fetchone()[0])

    def test_hidden_current_revision_does_not_trigger_compaction(self):
        self.seed_versions(('Active','Active','Active','Deleted'))
        self.assertEqual(0, self.db.execute(DUE, {'sourceId':1,'batch':1,'cutoff':CUTOFF}).fetchone()[0])

    def test_no_deleted_revisions_not_due(self):
        self.assertEqual(0, self.db.execute(DUE, {'sourceId':1,'batch':1,'cutoff':CUTOFF}).fetchone()[0])

    def test_prune_preserves_visible_and_hidden_snapshots_and_other_source(self):
        self.seed_versions()
        self.seed_versions(source=2)
        before = [self.snapshot(1,1), self.snapshot(1,4), self.snapshot(2,2)]
        after = None
        removed = 0
        for _ in range(10):
            after, inspected, count = prune_entries(self.db, 1, 1, after)
            self.assertLessEqual(inspected, 1)
            removed += count
        self.assertEqual(2, removed)
        self.assertEqual(before, [self.snapshot(1,1), self.snapshot(1,4), self.snapshot(2,2)])

    def test_all_retained_revision_combinations(self):
        for mask in range(16):
            db = sqlite3.connect(':memory:')
            db.executescript(SCHEMA)
            saved, self.db = self.db, db
            states = tuple('Active' if mask & (1 << n) else 'Deleted' for n in range(4))
            self.seed_versions(states)
            retained = [n for n in range(1,5) if states[n-1]=='Active' or n==4]
            before = [self.snapshot(1,n) for n in retained]
            prune_entries(self.db, 1, 1000)
            self.assertEqual(before, [self.snapshot(1,n) for n in retained])
            self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
            self.db.close()
            self.db = saved

    def test_global_sweep_finds_inactive_sources_without_new_backup(self):
        self.seed_versions()
        self.seed_versions(source=2)
        due = self.db.execute(DUE_SOURCES, {'batch':20, 'cutoff':CUTOFF, 'limit':1}).fetchall()
        self.assertEqual([(1,)], due)
        before = [self.snapshot(1,1), self.snapshot(1,4), self.snapshot(2,1), self.snapshot(2,4)]
        after = None
        removed = 0
        for _ in range(4):
            after, inspected, count = prune_entries(self.db, None, 3, after)
            self.assertLessEqual(inspected, 3)
            removed += count
        self.assertEqual(4, removed)
        self.assertEqual(before, [self.snapshot(1,1), self.snapshot(1,4), self.snapshot(2,1), self.snapshot(2,4)])

    def test_history_keeps_references_running_recent_and_incomplete(self):
        self.seed_history()
        self.db.execute("INSERT INTO revisions VALUES(1,1,1,'Active',NULL)")
        self.db.execute("INSERT INTO packs VALUES('pack',2)")
        self.db.execute("UPDATE runs SET status='Running' WHERE run_index=3")
        self.db.execute("UPDATE workflow_stages SET status='Running' WHERE run_index=4")
        self.db.execute("UPDATE workflow_runs SET completed_utc=NULL WHERE run_index=5")
        self.db.execute("UPDATE workflow_stages SET completed_utc=? WHERE run_index=6", (NEW,))
        self.db.execute("UPDATE workflow_runs SET completed_utc='unreadable' WHERE run_index=7")
        self.db.execute("UPDATE workflow_stages SET completed_utc=NULL WHERE run_index=8")
        self.db.commit()
        self.assertEqual((2,2,2), prune_history(self.db, keep=2))
        self.assertEqual([1,2,3,4,5,6,7,8,11,12], [r[0] for r in self.db.execute('SELECT run_index FROM runs ORDER BY 1')])
        self.assertEqual(10000, self.db.execute('SELECT next_run_index FROM repository_info').fetchone()[0])

    def test_history_batch_and_repeat(self):
        self.seed_history(6)
        self.assertEqual((2,2,2), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((2,2,2), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((1,1,1), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((0,0,0), prune_history(self.db, keep=1, limit=2))

    def test_latest_ids_of_each_history_are_kept(self):
        self.seed_history(4)
        self.db.execute("INSERT INTO workflow_runs VALUES(99,'maintenance',1,'Succeeded',?)", (OLD,))
        self.db.commit()
        prune_history(self.db, keep=1)
        self.assertEqual([(4,)], self.db.execute('SELECT run_index FROM runs').fetchall())
        self.assertEqual([(4,), (99,)], self.db.execute('SELECT run_index FROM workflow_runs ORDER BY 1').fetchall())

    def test_history_rollback_preserves_all_rows(self):
        self.seed_history()
        before = list(self.db.iterdump())
        self.db.execute('BEGIN')
        execute_many(self.db, HISTORY_SELECT, {'keep':1, 'cutoff':CUTOFF, 'limit':10})
        self.db.execute('DELETE FROM workflow_stages WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)')
        self.db.rollback()
        self.assertEqual(before, list(self.db.iterdump()))

    def test_active_work_excludes_only_maintenance_owner(self):
        self.seed_history(2)
        self.db.execute("UPDATE runs SET status='Running' WHERE run_index=1")
        self.assertEqual(1, self.db.execute(ACTIVE, {'run':2}).fetchone()[0])
        self.assertEqual(0, self.db.execute(ACTIVE, {'run':1}).fetchone()[0])

    def test_vacuum_reclaims_free_pages_and_preserves_rows(self):
        self.seed_history(5)
        self.db.execute('CREATE TABLE discarded(payload BLOB)')
        self.db.execute('INSERT INTO discarded VALUES(randomblob(8*1024*1024))')
        self.db.execute('DROP TABLE discarded')
        self.db.commit()
        before = self.db.execute('PRAGMA page_count').fetchone()[0]
        self.assertGreater(self.db.execute('PRAGMA freelist_count').fetchone()[0], 100)
        snapshot = list(self.db.iterdump())
        self.db.execute('VACUUM')
        self.assertLess(self.db.execute('PRAGMA page_count').fetchone()[0], before)
        self.assertEqual(snapshot, list(self.db.iterdump()))

    def test_wal_reader_can_defer_truncation_without_losing_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder)/'repo.db')
            writer = sqlite3.connect(path)
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute('PRAGMA busy_timeout=1')
            writer.execute('CREATE TABLE keep(value TEXT)')
            writer.execute("INSERT INTO keep VALUES('keep')")
            writer.commit()
            reader = sqlite3.connect(path)
            reader.execute('BEGIN')
            self.assertEqual('keep', reader.execute('SELECT value FROM keep').fetchone()[0])
            writer.execute('VACUUM')
            self.assertEqual(1, writer.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0])
            self.assertEqual('keep', reader.execute('SELECT value FROM keep').fetchone()[0])
            reader.close()
            self.assertEqual(0, writer.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0])
            writer.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
