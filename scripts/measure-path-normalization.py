#!/usr/bin/env python3
"""Compare schema-2 and normalized metadata in isolated databases; never access user data.

Both layouts use the exact same synthetic version history and are VACUUMed. Report
one snapshot as well as repeated histories; dictionary overhead is not hidden.
This is not an end-to-end backup throughput benchmark.
"""
from __future__ import annotations
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
SCHEMA_PATH='src/PzTools.Backup.Storage/Repository/RepositorySchema.cs'
NOW='2026-09-25T00:00:00+00:00'
TICKS=639258912000000000

def schema(source):
    return re.findall(r'"""\s*\n(.*?)\n\s*"""',source.split('internal static class RepositoryMigrationRunner')[0],re.S)[0]

def seed(db,sql,files,revisions,normalized):
    db.execute('PRAGMA page_size=4096');db.execute('PRAGMA foreign_keys=ON');db.executescript(sql)
    db.execute("INSERT INTO sources VALUES(1,'Sandbox/Synthetic','/not-a-user-save',?)",(NOW,))
    db.execute('INSERT INTO source_state(source_id,current_revision) VALUES(1,?)',(revisions,))
    pack=(1).to_bytes(16,'little');obj=(2).to_bytes(16,'little')
    names=[f'map/world/region_{i%16:02d}/chunk_{i:06d}.bin' for i in range(files)]
    for rev in range(1,revisions+1):
        db.execute("INSERT INTO runs VALUES(?,1,'Succeeded',?,?,NULL)",(rev,NOW,NOW))
        db.execute('INSERT INTO revisions(source_id,revision,run_index,created_utc,logical_size,file_count) VALUES(1,?,?,?,?,?)',
                   (rev,rev,NOW,files*128,files))
        if rev==1:
            db.execute("INSERT INTO packs VALUES(?,?,1,1,'Committed',1,?)",(pack,'packs/synthetic.pzpack',NOW))
            db.execute('INSERT INTO stored_objects VALUES(?,?,0,128,128,3,?,1,0,?)',(obj,pack,bytes(32),bytes(16)))
            if normalized:
                db.executemany('INSERT INTO paths VALUES(?,?)',[(i+1,n.upper()) for i,n in enumerate(names)])
                db.executemany('INSERT INTO path_spellings VALUES(?,0,?)',[(i+1,n) for i,n in enumerate(names)])
        entries=[]
        for i,name in enumerate(names):
            spelling=1 if rev>1 and rev%2==0 and i%10==0 else 0
            display=name.upper() if spelling else name
            if normalized and spelling:
                db.execute('INSERT INTO path_spellings SELECT ?,?,? WHERE NOT EXISTS (SELECT 1 FROM path_spellings WHERE path_id=? AND spelling_id=?)',(i+1,spelling,display,i+1,spelling))
            entries.append((1,i+1 if normalized else name.upper(),spelling if normalized else display,
                rev,rev+1 if rev<revisions else None,'File',0,128,TICKS+rev,TICKS+rev,32,
                (i+1).to_bytes(24,'big'),bytes(24),obj))
        db.executemany('INSERT INTO entry_versions VALUES('+','.join('?'*14)+')',entries)
    db.commit()
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    assert db.execute('PRAGMA integrity_check').fetchone()==('ok',)
    db.execute('VACUUM')

def snapshots(db,revisions,normalized):
    table='entry_catalog' if normalized else 'entry_versions'
    sql=f'''SELECT path_key,display_path,entry_kind,byte_length,modified_utc,object_id FROM {table}
        WHERE source_id=1 AND valid_from_revision<=? AND (valid_to_revision IS NULL OR valid_to_revision>?)
        AND tombstone=0 ORDER BY path_key'''
    for rev in {1,max(1,revisions//2),revisions}:
        yield db.execute(sql,(rev,rev)).fetchall()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref',default='9894bdd')
    parser.add_argument('--files',type=int,default=3000)
    parser.add_argument('--histories',type=int,nargs='+',default=[1,5,20])
    args=parser.parse_args()
    if not 1<=args.files<=100000 or any(not 1<=r<=100 for r in args.histories):parser.error('Fixture size out of bounds')
    before=schema(subprocess.check_output(['git','show',args.baseline_ref+':'+SCHEMA_PATH],cwd=ROOT,text=True))
    after=schema((ROOT/SCHEMA_PATH).read_text())
    output={'sqlite_version':sqlite3.sqlite_version,'files':args.files,'schema_sha256':{
        'before':hashlib.sha256(before.encode()).hexdigest(),'after':hashlib.sha256(after.encode()).hexdigest()},'profiles':[]}
    with tempfile.TemporaryDirectory(prefix='pz-path-layout-') as temp:
        for revisions in args.histories:
            result={'revisions':revisions,'entry_versions':args.files*revisions}
            with closing(sqlite3.connect(Path(temp)/f'old-{revisions}.db')) as old,closing(sqlite3.connect(Path(temp)/f'new-{revisions}.db')) as new:
                for name,db,sql,normalized in [('before',old,before,False),('after',new,after,True)]:
                    start=time.perf_counter();seed(db,sql,args.files,revisions,normalized)
                    result[name]={'bytes':db.execute('PRAGMA page_count').fetchone()[0]*4096,
                        'freelist_pages':db.execute('PRAGMA freelist_count').fetchone()[0],
                        'fixture_creation_ms':round((time.perf_counter()-start)*1000,2)}
                assert list(snapshots(old,revisions,False))==list(snapshots(new,revisions,True))
                result['checked_history_snapshots_equal']=True
                result['paths']=new.execute('SELECT COUNT(*) FROM paths').fetchone()[0]
                result['spellings']=new.execute('SELECT COUNT(*) FROM path_spellings').fetchone()[0]
                result['reduction_percent']=round((1-result['after']['bytes']/result['before']['bytes'])*100,2)
            output['profiles'].append(result)
    print(json.dumps(output,indent=2))
if __name__=='__main__':main()
