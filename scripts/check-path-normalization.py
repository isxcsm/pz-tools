#!/usr/bin/env python3
"""Exercise production schema, path interning/GC and staging SQL in private in-memory DBs."""
import sqlite3
import unittest

from repository_sql import add_run, block, constant, schema, source

SCHEMA = schema(source('RepositorySchema.cs'))
PATHS = source('RepositoryDatabase.Paths.cs')
INTERN_PATH = block(PATHS, 'INSERT INTO paths(path_key) VALUES($key)', 'RepositoryDatabase.Paths.cs')
INTERN_SPELLING = block(PATHS, 'INSERT INTO path_spellings(', 'RepositoryDatabase.Paths.cs')
COLLECTION = source('RepositoryDatabase.PathCollection.cs')
SPELL_WINDOW, PATH_WINDOW, GC_SPELLING, GC_PATH = (
    constant(COLLECTION, name, 'RepositoryDatabase.PathCollection.cs') for name in
    ('PathSpellingWindowSql', 'EmptyPathWindowSql', 'DeleteUnreferencedSpellingSql', 'DeleteEmptyPathSql'))
INITIAL = block(source('RepositoryDatabase.InitialStaging.cs'), 'FROM full_scan_entries AS scan', 'RepositoryDatabase.InitialStaging.cs')
CATALOG = constant(source('RepositoryDatabase.Summaries.cs'), 'CatalogSummarySql', 'RepositoryDatabase.Summaries.cs')

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
    sp, si, p, first = db.execute('SELECT spelling_path_id,spelling_id,empty_path_id,spellings_first FROM path_gc_cursor').fetchone()
    if maximum > 1: first = True
    inspected = removed = 0
    for phase in range(2):
        limit = (maximum+1)//2 if phase == 0 else maximum-inspected
        if limit == 0: continue
        if (phase == 0) == bool(first):
            rows = db.execute(SPELL_WINDOW, {'afterPath':sp,'afterSpelling':si,'limit':limit}).fetchall()
            for path, spelling, unreferenced in rows:
                sp,si = path,spelling
                if unreferenced: removed += db.execute(GC_SPELLING, {'pathId':path,'spellingId':spelling}).rowcount
            if len(rows)<limit: sp,si = -(1<<63),-1
        else:
            sql=PATH_WINDOW.replace('/*cursor*/','' if p is None else 'WHERE path.path_id>$afterPath')
            rows = db.execute(sql, {'afterPath':p,'limit':limit}).fetchall()
            for path, empty in rows:
                p=path
                if empty: removed += db.execute(GC_PATH, {'pathId':path}).rowcount
            if len(rows)<limit: p=None
        inspected += len(rows)
    assert 0 <= removed <= inspected <= maximum
    db.execute('UPDATE path_gc_cursor SET spelling_path_id=?,spelling_id=?,empty_path_id=?,spellings_first=?', (sp,si,p,not first))
    return removed

class PathNormalizationSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.executescript(SCHEMA)
        self.db.execute("INSERT INTO sources VALUES(1,'Sandbox/One','/synthetic','2000-01-01')")
        self.db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,1)')
        add_run(self.db, 1, 1, '2000-01-01')
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
        for _ in range(40):
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
        plan=[r[3] for r in self.db.execute('EXPLAIN QUERY PLAN '+SPELL_WINDOW,{'limit':1000,'afterPath':0,'afterSpelling':0})]
        self.assertTrue(any('ix_entry_versions_spelling' in r for r in plan),plan)

if __name__=='__main__':
    print('SQLite',sqlite3.sqlite_version)
    unittest.main()
