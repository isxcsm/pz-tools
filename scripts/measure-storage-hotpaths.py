#!/usr/bin/env python3
"""Compare production lookup SQL on isolated synthetic schemas, never user backups.

Run from a checkout containing dev 52e8822:
    python scripts/measure-storage-hotpaths.py --baseline-ref 52e8822
Timings exclude fixture construction, .NET calls, disk I/O and UI/backup execution.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import sqlite3
import statistics
import time

from repository_sql import add_run, block, blocks, constant as sql_constant, schema, source as text

def constant(value: str, name: str) -> str:
    match = re.search(r'const string ' + re.escape(name) + r'\s*=\s*(.*?);', value, re.S)
    if not match:
        raise ValueError(f'Constant {name} not found')
    return ''.join(re.findall(r'"([^"\n]*)"', match[1]))

def make_db(schema: str, entries: int, packs: int) -> sqlite3.Connection:
    db = sqlite3.connect(':memory:')
    try:
        db.execute('PRAGMA foreign_keys=ON')
        db.executescript(schema)
        db.execute("INSERT INTO sources VALUES(1,'Sandbox/Fixture','/isolated','2000-01-01')")
        db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,3)')
        for revision in range(1, 4):
            add_run(db, revision, 1, '2000-01-01')
            db.execute("INSERT INTO revisions(source_id,revision,run_index,created_utc,logical_size,file_count) VALUES(1,?,?,'2000-01-01',?,?)",
                       (revision, revision, entries*1024, entries))
        for i in range(packs + 100):
            db.execute("INSERT INTO packs VALUES(?,?,2,1000000,'Committed',1,'2000-01-01')",
                       ((i+1).to_bytes(16, 'big'), f'packs/{i}.pzpack'))
        ids = [hashlib.sha256(f'object-{i}'.encode()).digest()[:16] for i in range(entries)]
        db.executemany('INSERT INTO stored_objects VALUES(?,?,0,1024,1024,2,?,1,0,?)',
                       ((ids[i], (i % packs+1).to_bytes(16,'big'), b'checksum', b'h'*16) for i in range(entries)))
        db.executemany('INSERT INTO paths VALUES(?,?)', ((i+1,f'MODS/REGION/ITEM-{i:06}') for i in range(entries)))
        db.executemany('INSERT INTO path_spellings VALUES(?,0,?)', ((i+1,f'mods/region/item-{i:06}') for i in range(entries)))
        for rev in range(1, 4):
            db.executemany("INSERT INTO entry_versions VALUES(1,?,0,?,?,'File',0,1024,100,100,128,?,?,?)",
                           ((i+1, rev, rev+1 if rev<3 else None,
                             (1).to_bytes(8,'big')+(i+1).to_bytes(16,'big'), b'p'*24, ids[i]) for i in range(entries)))
        db.commit()
        db.execute('VACUUM')
        assert db.execute('PRAGMA foreign_key_check').fetchall() == []
        assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
        return db
    except BaseException:
        db.close()
        raise

def measure(db, sql, params, repetitions):
    expected = db.execute(sql, params).fetchall()
    times=[]
    for _ in range(repetitions):
        start=time.perf_counter_ns()
        actual=db.execute(sql,params).fetchall()
        times.append((time.perf_counter_ns()-start)/1e6)
        assert actual == expected
    plan=[r[3] for r in db.execute('EXPLAIN QUERY PLAN '+sql,params)]
    return expected, {'median_ms': round(statistics.median(times),4), 'plan': plan, 'rows':len(expected)}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-ref',default='52e8822')
    p.add_argument('--entries',type=int,default=22000)
    p.add_argument('--packs',type=int,default=200)
    p.add_argument('--repetitions',type=int,default=3)
    args=p.parse_args()
    if args.entries<1100 or args.packs<1 or args.repetitions<1: p.error('entries>=1100; packs and repetitions>=1')
    before_schema=schema(text('RepositorySchema.cs',args.baseline_ref))
    after_schema=schema(text('RepositorySchema.cs'))
    before_read=text('RepositoryDatabase.Read.cs',args.baseline_ref)
    after_read=text('RepositoryDatabase.Read.cs')
    lookup=text('RepositoryDatabase.Lookups.cs')
    old_paths=block(before_read,'{joinClause}','baseline RepositoryDatabase.Read.cs').replace('{joinClause}',
        re.search(r'"(JOIN paths AS requested_path[^"\n]+)"',before_read)[1])
    old_refs=block(before_read,'SELECT entry.display_path, entry.entry_kind, entry.file_id','baseline RepositoryDatabase.Read.cs')
    new_paths=block(after_read,'{fromClause}','RepositoryDatabase.Read.cs')
    new_refs=[sql_constant(lookup,name,'RepositoryDatabase.Lookups.cs') for name in ('TrackedPathsRequestFirstSql','TrackedPathsScanSql')]
    threshold=int(re.search(r'RequestDrivenLookupThreshold\s*=\s*(\d+)',lookup)[1])
    before=make_db(before_schema,args.entries,args.packs)
    after=None
    try:
        after=make_db(after_schema,args.entries,args.packs)
        sizes=[db.execute('PRAGMA page_count').fetchone()[0]*db.execute('PRAGMA page_size').fetchone()[0] for db in (before,after)]
        result={'sqlite':sqlite3.sqlite_version,'fixture':vars(args),'database_bytes':{'before':sizes[0],'after':sizes[1],'delta':sizes[1]-sizes[0]},'queries':[]}
        pack_sql="SELECT relative_path FROM packs WHERE NOT EXISTS (SELECT 1 FROM stored_objects WHERE stored_objects.pack_id=packs.pack_id) ORDER BY relative_path;"
        left,lt=measure(before,pack_sql,{},args.repetitions)
        right,rt=measure(after,pack_sql,{},args.repetitions)
        assert left == right
        result['queries'].append({'kind':'empty-pack lookup', 'before':lt,'after':rt})
        for count in (10,1024,min(8000,args.entries)):
            for db in (before,after):
                db.executescript('DROP TABLE IF EXISTS temp.requested_paths; DROP TABLE IF EXISTS temp.requested_file_references;'
                                 'CREATE TEMP TABLE requested_paths(path_key TEXT PRIMARY KEY) WITHOUT ROWID;'
                                 'CREATE TEMP TABLE requested_file_references(value BLOB PRIMARY KEY) WITHOUT ROWID;')
                db.executemany('INSERT INTO requested_paths VALUES(?)',((f'MODS/REGION/ITEM-{i:06}',) for i in range(count)))
                db.executemany('INSERT INTO requested_file_references VALUES(?)',(((i+1).to_bytes(16,'big'),) for i in range(count)))
                db.commit()
            for kind,old,new in [('paths',old_paths,new_paths.replace('{fromClause}',constant(lookup,'PathsRequestFirstFrom' if count<=threshold else 'PathsScanFrom'))),
                                 ('file references',old_refs,new_refs[0 if count<=threshold else 1])]:
                left,lt=measure(before,old,{'sourceId':1},args.repetitions)
                right,rt=measure(after,new,{'sourceId':1},args.repetitions)
                assert sorted(left) == sorted(right),kind
                result['queries'].append({'kind':kind,'request_count':count,'before':lt,'after':rt})
        window=sql_constant(text('RepositoryDatabase.PathCollection.cs'),'PathSpellingWindowSql','RepositoryDatabase.PathCollection.cs')
        rows,stats=measure(after,window,{'afterPath':0,'afterSpelling':-1,'limit':1000},args.repetitions)
        assert len(rows)==1000 and all(row[2]==0 for row in rows)
        result['bounded_live_spelling_window']=stats
        print(json.dumps(result,indent=2))
    finally:
        before.close()
        if after is not None: after.close()

if __name__=='__main__': main()
