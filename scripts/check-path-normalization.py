#!/usr/bin/env python3
"""Exercise production schema, path interning/GC and staging SQL in private in-memory DBs."""
from contextlib import closing
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'src/PzTools.Backup.Storage/Repository'
def sqls(name):
    return re.findall(r'"""\s*\n(.*?)\n\s*"""', (ROOT/name).read_text(), re.S)
SCHEMA = sqls('RepositorySchema.cs')[0]
INTERN_PATH, INTERN_SPELLING, GC_SPELLING, GC_PATH = sqls('RepositoryDatabase.Paths.cs')
INITIAL = sqls('RepositoryDatabase.InitialStaging.cs')[-1]
CATALOG = sqls('RepositoryDatabase.Summaries.cs')[0]

def batch(db, sql, parameters):
    result = None
    for statement in sql.split(';'):
        if statement.strip():
            result = db.execute(statement, parameters)
    return result

def intern(db, display):
    # ASCII fixtures here; the C# suite covers the actual .NET Unicode casing contract.
    path = batch(db, INTERN_PATH, {'key': display.upper()}).fetchone()[0]
    spelling = batch(db, INTERN_SPELLING, {'id': path, 'display': display}).fetchone()[0]
    return path, spelling

def gc(db, maximum):
    removed = db.execute(GC_SPELLING, {'limit': maximum}).rowcount
    return removed + db.execute(GC_PATH, {'limit': maximum-removed}).rowcount

class PathNormalizationSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript(SCHEMA)
        self.db.execute("INSERT INTO sources VALUES(1,'Sandbox/One','/synthetic','2000-01-01')")
        self.db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,1)')
        self.db.execute("INSERT INTO runs(run_index,source_id,status,started_utc) VALUES(1,1,'Succeeded','2000-01-01')")
        self.db.execute("INSERT INTO revisions(source_id,revision,run_index,created_utc) VALUES(1,1,1,'2000-01-01')")
        self.db.commit()
    def tearDown(self):
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
        self.assertEqual(('ok',), self.db.execute('PRAGMA integrity_check').fetchone())
        self.db.close()
    def entry(self, pair):
        self.db.execute("""INSERT INTO entry_versions(source_id,path_id,spelling_id,valid_from_revision,
            entry_kind,tombstone,byte_length,modified_utc,changed_utc,attributes)
            VALUES(1,?,?,1,'Directory',0,0,0,0,16)""", pair)
    def test_intern_reuses_identity_and_exact_spelling(self):
        first = intern(self.db,'Folder/A')
        second = intern(self.db,'FOLDER/a')
        self.assertEqual(first, intern(self.db,'Folder/A'))
        self.assertEqual(first[0], second[0])
        self.assertNotEqual(first[1],second[1])
    def test_no_repeated_path_text_in_versions(self):
        columns = {r[1] for r in self.db.execute("PRAGMA table_info('entry_versions')")}
        self.assertFalse(columns & {'path_key','display_path'})
        pair=intern(self.db,'Folder/A'); self.entry(pair)
        self.assertEqual(('FOLDER/A','Folder/A'),self.db.execute('SELECT path_key,display_path FROM entry_catalog').fetchone())
    def test_dictionary_and_entry_rollback_together(self):
        self.entry(intern(self.db,'Keep')); self.db.commit()
        self.entry(intern(self.db,'Not-committed')); self.db.rollback()
        self.assertEqual([('Keep',)],self.db.execute('SELECT display_path FROM entry_catalog').fetchall())
        self.assertEqual(1,self.db.execute('SELECT COUNT(*) FROM paths').fetchone()[0])
    def test_immutable_names_and_referenced_delete(self):
        self.entry(intern(self.db,'Keep')); self.db.commit()
        for sql in ["UPDATE paths SET path_key='OTHER'", "UPDATE path_spellings SET display_path='Other'", 'DELETE FROM path_spellings']:
            with self.assertRaises(sqlite3.IntegrityError): self.db.execute(sql)
    def test_mismatched_spelling_reference_is_rejected(self):
        pair = intern(self.db,'Keep')
        with self.assertRaises(sqlite3.IntegrityError): self.entry((pair[0],999))
    def test_current_case_alias_cannot_create_duplicate(self):
        self.entry(intern(self.db,'Keep'))
        with self.assertRaises(sqlite3.IntegrityError): self.entry(intern(self.db,'KEEP'))
    def test_gc_is_bounded_keeps_referenced_names_and_drains(self):
        self.entry(intern(self.db,'Keep'))
        for n in range(7): intern(self.db,f'unused-{n}')
        removed=0
        for _ in range(10):
            count=gc(self.db,3); self.assertLessEqual(count,3);removed+=count
        self.assertEqual(14,removed)
        self.assertEqual([('Keep',)],self.db.execute('SELECT display_path FROM entry_catalog').fetchall())
    def test_initial_bulk_path_interning_and_rollback(self):
        intern(self.db,'folder')
        self.db.execute('''CREATE TEMP TABLE full_scan_entries(path_key TEXT PRIMARY KEY,display_path TEXT,entry_kind TEXT,
            byte_length INTEGER,modified_utc INTEGER,changed_utc INTEGER,attributes INTEGER,file_id BLOB,parent_file_id BLOB,object_id BLOB)''')
        self.db.execute("INSERT INTO full_scan_entries VALUES('FOLDER','FOLDER','Directory',0,0,0,16,NULL,NULL,NULL)")
        self.db.commit()
        batch(self.db,INITIAL,{'sourceId':1,'revision':1})
        self.assertEqual(1,self.db.execute('SELECT COUNT(*) FROM paths').fetchone()[0])
        self.assertEqual(2,self.db.execute('SELECT COUNT(*) FROM path_spellings').fetchone()[0])
        self.db.rollback()
        self.assertEqual(1,self.db.execute('SELECT COUNT(*) FROM path_spellings').fetchone()[0])
        self.assertEqual(0,self.db.execute('SELECT COUNT(*) FROM entry_versions').fetchone()[0])
    def test_catalog_resolves_numeric_path_range(self):
        plan=[r[3] for r in self.db.execute('EXPLAIN QUERY PLAN '+CATALOG,{'metadataPathKey':'PLAYERS.DB'})]
        self.assertTrue(any('SEARCH entry' in r and 'path_id=?' in r for r in plan),plan)
        self.assertFalse(any('SCAN entry' in r for r in plan),plan)
    def test_gc_lookup_uses_composite_reference_index(self):
        plan=[r[3] for r in self.db.execute('EXPLAIN QUERY PLAN '+GC_SPELLING,{'limit':1000})]
        self.assertTrue(any('ix_entry_versions_spelling' in r for r in plan),plan)

if __name__=='__main__':
    print('SQLite',sqlite3.sqlite_version)
    unittest.main()
