#!/usr/bin/env python3
"""Execute production housekeeping SQL against isolated SQLite fixtures.

The fixture is the production schema itself, read from RepositorySchema.cs, and every statement
under test is read from the C# source, so the check fails loudly when either changes shape.
This supplements, not replaces, the dotnet RepositoryHousekeepingTests.
"""
import sqlite3
import tempfile
import unittest
from pathlib import Path

import repository_sql


def block(name, marker):
    return repository_sql.block(repository_sql.source(name), marker, name)


SCHEMA = repository_sql.schema(repository_sql.source('RepositorySchema.cs'))
HOUSEKEEPING = 'RepositoryDatabase.Housekeeping.cs'
DUE = block(HOUSEKEEPING, 'SELECT COUNT(*) >= $batch')
DUE_SOURCES = block(HOUSEKEEPING, 'SELECT revision.source_id FROM revisions')
HISTORY_SELECT = block(HOUSEKEEPING, 'CREATE TEMP TABLE housekeeping_recent')
ACTIVE = block(HOUSEKEEPING, 'FROM worker_runs')
ENTRY_WINDOW = block('RepositoryDatabase.EntryCollection.cs', '/*cursor*/')
CUTOFF = '2026-01-01T00:00:00.0000000+00:00'
OLD = '2000-01-01T00:00:00.0000000+00:00'
NEW = '2099-01-01T00:00:00.0000000+00:00'


def execute_many(db, sql, params):
    for statement in sql.split(';'):
        if statement.strip():
            db.execute(statement, params)


def prune_entries(db, source, limit, after=None):
    sql = ENTRY_WINDOW.replace('/*cursor*/', 'WHERE entry.rowid>$after' if after is not None else '')
    rows = db.execute(sql, {'sourceId': source, 'limit': limit, 'after': after}).fetchall()
    removed = 0
    for rowid, eligible in rows:
        if eligible:
            removed += db.execute('DELETE FROM entry_versions WHERE rowid=?', (rowid,)).rowcount
    return (rows[-1][0] if len(rows) == limit else None), len(rows), removed


def prune_history(db, keep=1, limit=1000):
    """PruneCompletedHistoryAsync: one transaction, stages then workflows."""
    params = {'keep': keep, 'cutoff': CUTOFF, 'limit': limit}
    with db:
        execute_many(db, HISTORY_SELECT, params)
        stages = db.execute('DELETE FROM workflow_stages WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)').rowcount
        workflows = db.execute('DELETE FROM workflow_runs WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)').rowcount
    # Production opens a fresh connection each time, so its temporary tables start empty.
    db.execute('DROP TABLE housekeeping_recent')
    db.execute('DROP TABLE housekeeping_workflows')
    return workflows, stages


class HousekeepingSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = self.open()

    @staticmethod
    def open(path=':memory:'):
        db = sqlite3.connect(path)
        db.execute('PRAGMA foreign_keys=ON')
        db.executescript(SCHEMA)
        db.execute('INSERT INTO repository_info(singleton,repository_id,format_version,schema_version,next_run_index,created_utc) '
                   'VALUES(1,randomblob(16),1,6,10000,?)', (OLD,))
        for source in (1, 2):
            db.execute('INSERT INTO sources VALUES(?,?,?,?)', (source, f'Sandbox/{source}', f'C:/saves/{source}', OLD))
            db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(?,4)', (source,))
        db.execute("INSERT INTO paths VALUES(1,'A')")
        db.execute("INSERT INTO path_spellings VALUES(1,0,'A')")
        db.commit()
        return db

    def tearDown(self):
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
        self.assertEqual('ok', self.db.execute('PRAGMA integrity_check').fetchone()[0])
        self.db.close()

    def workflow(self, run, pipeline='backup', owner='backup-worker', source=1, status='Succeeded', completed=OLD, producer=None):
        self.db.execute('INSERT INTO workflow_runs(run_index,pipeline,source_id,owner_component,status,started_utc,completed_utc) '
                        'VALUES(?,?,?,?,?,?,?)', (run, pipeline, source, owner, status, OLD, completed))
        self.db.execute('INSERT INTO workflow_stages(run_index,producer,status,started_utc,completed_utc) VALUES(?,?,?,?,?)',
                        (run, producer or owner, status, OLD, completed))

    def seed_history(self, count=12):
        for run in range(1, count + 1):
            self.workflow(run)
        self.db.commit()

    def seed_versions(self, states=('Active', 'Deleted', 'Deleted', 'Deleted'), source=1):
        for revision, state in enumerate(states, 1):
            run = source * 100 + revision
            self.workflow(run, source=source)
            self.db.execute('INSERT INTO revisions(source_id,revision,run_index,created_utc,state,deleted_utc) VALUES(?,?,?,?,?,?)',
                            (source, revision, run, OLD, state, OLD if state == 'Deleted' else None))
            self.db.execute("INSERT INTO entry_versions(source_id,path_id,spelling_id,valid_from_revision,valid_to_revision,"
                            "entry_kind,tombstone,byte_length,modified_utc,changed_utc,attributes) "
                            "VALUES(?,1,0,?,?,'Directory',?,0,0,0,16)",
                            (source, revision, revision + 1 if revision < 4 else None, 1 if revision == 4 else 0))
        self.db.commit()

    def snapshot(self, source, revision):
        return self.db.execute('SELECT * FROM entry_versions WHERE source_id=? AND valid_from_revision<=? '
                               'AND (valid_to_revision IS NULL OR valid_to_revision>?) ORDER BY path_id',
                               (source, revision, revision)).fetchall()

    def test_small_old_deletion_becomes_due(self):
        self.seed_versions()
        self.assertEqual(1, self.db.execute(DUE, {'sourceId': 1, 'batch': 20, 'cutoff': CUTOFF}).fetchone()[0])

    def test_recent_deletions_remain_batched(self):
        self.seed_versions()
        self.db.execute("UPDATE revisions SET deleted_utc=? WHERE state='Deleted'", (NEW,))
        self.assertEqual(0, self.db.execute(DUE, {'sourceId': 1, 'batch': 20, 'cutoff': CUTOFF}).fetchone()[0])
        self.assertEqual(1, self.db.execute(DUE, {'sourceId': 1, 'batch': 2, 'cutoff': CUTOFF}).fetchone()[0])

    def test_hidden_current_revision_does_not_trigger_compaction(self):
        self.seed_versions(('Active', 'Active', 'Active', 'Deleted'))
        self.assertEqual(0, self.db.execute(DUE, {'sourceId': 1, 'batch': 1, 'cutoff': CUTOFF}).fetchone()[0])

    def test_no_deleted_revisions_not_due(self):
        self.assertEqual(0, self.db.execute(DUE, {'sourceId': 1, 'batch': 1, 'cutoff': CUTOFF}).fetchone()[0])

    def test_prune_preserves_visible_and_hidden_snapshots_and_other_source(self):
        self.seed_versions()
        self.seed_versions(source=2)
        before = [self.snapshot(1, 1), self.snapshot(1, 4), self.snapshot(2, 2)]
        after = None
        removed = 0
        for _ in range(10):
            after, inspected, count = prune_entries(self.db, 1, 1, after)
            self.assertLessEqual(inspected, 1)
            removed += count
        self.assertEqual(2, removed)
        self.assertEqual(before, [self.snapshot(1, 1), self.snapshot(1, 4), self.snapshot(2, 2)])

    def test_all_retained_revision_combinations(self):
        for mask in range(16):
            saved, self.db = self.db, self.open()
            states = tuple('Active' if mask & (1 << n) else 'Deleted' for n in range(4))
            self.seed_versions(states)
            retained = [n for n in range(1, 5) if states[n - 1] == 'Active' or n == 4]
            before = [self.snapshot(1, n) for n in retained]
            prune_entries(self.db, 1, 1000)
            self.assertEqual(before, [self.snapshot(1, n) for n in retained])
            self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
            self.db.close()
            self.db = saved

    def test_global_sweep_finds_inactive_sources_without_new_backup(self):
        self.seed_versions()
        self.seed_versions(source=2)
        due = self.db.execute(DUE_SOURCES, {'batch': 20, 'cutoff': CUTOFF, 'limit': 1}).fetchall()
        self.assertEqual([(1,)], due)
        before = [self.snapshot(1, 1), self.snapshot(1, 4), self.snapshot(2, 1), self.snapshot(2, 4)]
        after = None
        removed = 0
        for _ in range(4):
            after, inspected, count = prune_entries(self.db, None, 3, after)
            self.assertLessEqual(inspected, 3)
            removed += count
        self.assertEqual(4, removed)
        self.assertEqual(before, [self.snapshot(1, 1), self.snapshot(1, 4), self.snapshot(2, 1), self.snapshot(2, 4)])

    def test_history_keeps_references_running_recent_and_incomplete(self):
        self.seed_history()
        self.db.execute('INSERT INTO revisions(source_id,revision,run_index,created_utc) VALUES(1,1,1,?)', (OLD,))
        self.db.execute("INSERT INTO packs VALUES(randomblob(16),'packs/a.pzpack',1,0,'Committed',2,?)", (OLD,))
        self.db.execute("UPDATE workflow_runs SET status='Running' WHERE run_index=3")
        self.db.execute("UPDATE workflow_stages SET status='Running' WHERE run_index=4")
        self.db.execute('UPDATE workflow_runs SET completed_utc=NULL WHERE run_index=5')
        self.db.execute('UPDATE workflow_stages SET completed_utc=? WHERE run_index=6', (NEW,))
        self.db.execute("UPDATE workflow_runs SET completed_utc='unreadable' WHERE run_index=7")
        self.db.execute('UPDATE workflow_stages SET completed_utc=NULL WHERE run_index=8')
        self.db.commit()
        self.assertEqual((2, 2), prune_history(self.db, keep=2))
        self.assertEqual([1, 2, 3, 4, 5, 6, 7, 8, 11, 12],
                         [r[0] for r in self.db.execute('SELECT run_index FROM workflow_runs ORDER BY 1')])
        self.assertEqual(10000, self.db.execute('SELECT next_run_index FROM repository_info').fetchone()[0])

    def test_history_batch_and_repeat(self):
        self.seed_history(6)
        self.assertEqual((2, 2), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((2, 2), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((1, 1), prune_history(self.db, keep=1, limit=2))
        self.assertEqual((0, 0), prune_history(self.db, keep=1, limit=2))

    def test_newest_run_indexes_are_kept_whatever_their_pipeline(self):
        self.seed_history(4)
        self.workflow(99, pipeline='maintenance', owner='maintenance-worker')
        self.db.commit()
        prune_history(self.db, keep=2)
        self.assertEqual([(4,), (99,)], self.db.execute('SELECT run_index FROM workflow_runs ORDER BY 1').fetchall())

    def test_history_rollback_preserves_all_rows(self):
        self.seed_history()
        before = list(self.db.iterdump())
        self.db.execute('BEGIN')
        execute_many(self.db, HISTORY_SELECT, {'keep': 1, 'cutoff': CUTOFF, 'limit': 10})
        self.db.execute('DELETE FROM workflow_stages WHERE run_index IN (SELECT run_index FROM housekeeping_workflows)')
        self.db.rollback()
        self.assertEqual(before, list(self.db.iterdump()))

    def test_active_work_blocks_vacuum_except_maintenance_itself(self):
        self.seed_history(2)
        self.assertEqual(0, self.db.execute(ACTIVE, {'run': 2}).fetchone()[0])
        # A backup worker still running in another run.
        self.db.execute("UPDATE workflow_runs SET status='Running' WHERE run_index=1")
        self.db.execute("UPDATE workflow_stages SET status='Running' WHERE run_index=1")
        self.assertEqual(1, self.db.execute(ACTIVE, {'run': 2}).fetchone()[0])
        self.assertEqual(0, self.db.execute(ACTIVE, {'run': 1}).fetchone()[0])
        self.db.execute("UPDATE workflow_stages SET status='Succeeded' WHERE run_index=1")
        # A reserved backup workflow whose worker has not started yet.
        self.assertEqual(1, self.db.execute(ACTIVE, {'run': 2}).fetchone()[0])
        self.db.execute("UPDATE workflow_runs SET status='Succeeded' WHERE run_index=1")
        # Other maintenance lanes do not block it.
        self.workflow(3, pipeline='maintenance-lane', owner='maintenance-lane-OrphanBackups', source=None, status='Running', completed=None)
        self.assertEqual(0, self.db.execute(ACTIVE, {'run': 2}).fetchone()[0])

    def test_vacuum_reclaims_free_pages_and_preserves_rows(self):
        self.seed_history(5)
        self.db.execute('CREATE TABLE discarded(payload BLOB)')
        self.db.execute('INSERT INTO discarded VALUES(randomblob(8*1024*1024))')
        self.db.execute('DROP TABLE discarded')
        self.db.commit()
        before = self.db.execute('PRAGMA page_count').fetchone()[0]
        self.assertGreater(self.db.execute('PRAGMA freelist_count').fetchone()[0], 100)
        # VACUUM may renumber root pages, which changes the order the dump lists schema objects in.
        snapshot = sorted(self.db.iterdump())
        self.db.execute('VACUUM')
        self.assertLess(self.db.execute('PRAGMA page_count').fetchone()[0], before)
        self.assertEqual(snapshot, sorted(self.db.iterdump()))

    def test_wal_reader_can_defer_truncation_without_losing_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / 'repo.db')
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
