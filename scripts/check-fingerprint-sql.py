"""Supplemental SQL checks; production C# tests remain the integration authority."""
import hashlib
import pathlib
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
PRODUCTION = ROOT / 'ContentFingerprintMigration.cs'
if not PRODUCTION.exists():
    PRODUCTION = ROOT.parent / 'src/PzTools.Backup.Storage/Repository/ContentFingerprintMigration.cs'
SQL = PRODUCTION.read_text(encoding='utf-8').split('"""')[1]
STATEMENTS = [part.strip() for part in SQL.split(';') if part.strip()]
DIGEST = hashlib.sha256(b'original payload').digest()


def fixture():
    db = sqlite3.connect(':memory:', isolation_level=None)
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript('''
        CREATE TABLE repository_info(singleton INTEGER PRIMARY KEY,schema_version INTEGER);
        INSERT INTO repository_info VALUES(1,11);
        CREATE TABLE packs(pack_id TEXT PRIMARY KEY);
        INSERT INTO packs VALUES('pack');
        CREATE TABLE stored_objects(
            object_id TEXT PRIMARY KEY, pack_id TEXT REFERENCES packs(pack_id),
            checksum_algorithm TEXT,checksum BLOB,
            content_hash_algorithm TEXT CHECK(content_hash_algorithm IS NULL OR content_hash_algorithm='Sha256'),
            content_hash BLOB CHECK((content_hash IS NULL AND content_hash_algorithm IS NULL)
                OR (content_hash IS NOT NULL AND length(content_hash)=32 AND content_hash_algorithm IS NOT NULL))
        ) STRICT;
        CREATE TABLE entry_versions(object_id TEXT REFERENCES stored_objects(object_id));
    ''')
    db.execute('INSERT INTO stored_objects VALUES(?,?,?,?,?,?)',
               ('object','pack','Sha256',DIGEST,'Sha256',DIGEST))
    db.execute('INSERT INTO stored_objects VALUES(?,?,?,?,?,?)',
               ('no-hash','pack','Sha256',DIGEST,None,None))
    db.execute("INSERT INTO entry_versions VALUES('object')")
    return db


def migrate(db, stop=None):
    db.execute('BEGIN IMMEDIATE')
    try:
        for index, statement in enumerate(STATEMENTS):
            db.execute(statement)
            if index == stop:
                raise RuntimeError('injected migration interruption')
        db.commit()
    except BaseException:
        db.rollback()
        raise


class FingerprintSqlTests(unittest.TestCase):
    def test_conversion_preserves_refs_and_checksum(self):
        db = fixture()
        migrate(db)
        self.assertEqual(('Sha256_128',DIGEST[:16],DIGEST), db.execute(
            "SELECT content_hash_algorithm,content_hash,checksum FROM stored_objects WHERE object_id='object'").fetchone())
        self.assertEqual([],db.execute('PRAGMA foreign_key_check').fetchall())
        self.assertEqual(('ok',), db.execute('PRAGMA integrity_check').fetchone())
        self.assertEqual((12,), db.execute('SELECT schema_version FROM repository_info').fetchone())
        self.assertEqual((1,), db.execute('SELECT count(*) FROM entry_versions').fetchone())
        db.close()

    def test_null_remains_null(self):
        db = fixture(); migrate(db)
        self.assertEqual((None,None), db.execute(
            "SELECT content_hash_algorithm,content_hash FROM stored_objects WHERE object_id='no-hash'").fetchone())
        db.close()

    def test_rollback_at_every_statement_boundary(self):
        for stop in range(len(STATEMENTS)):
            with self.subTest(stop=stop):
                db=fixture()
                with self.assertRaises(RuntimeError): migrate(db,stop)
                self.assertEqual(('Sha256',DIGEST,DIGEST), db.execute(
                    "SELECT content_hash_algorithm,content_hash,checksum FROM stored_objects WHERE object_id='object'").fetchone())
                self.assertEqual((11,), db.execute('SELECT schema_version FROM repository_info').fetchone())
                self.assertEqual([], db.execute('PRAGMA foreign_key_check').fetchall())
                self.assertEqual([],db.execute("SELECT name FROM sqlite_temp_master WHERE name='migration_content_fingerprints'").fetchall())
                db.close()

    def test_invalid_algorithm_length_pairs_are_rejected(self):
        db=fixture(); migrate(db)
        for algorithm,size in [('Sha256',16),('Sha256_128',32),('Sha256_128',0),('unknown',16),(None,16),('Sha256_128',None)]:
            with self.subTest(algorithm=algorithm,size=size):
                with self.assertRaises(sqlite3.IntegrityError):
                    db.execute("UPDATE stored_objects SET content_hash_algorithm=?,content_hash=? WHERE object_id='object'",
                               (algorithm,bytes(size) if size is not None else None))
        db.close()

    def test_legacy_32_byte_write_remains_readable(self):
        db=fixture(); migrate(db)
        db.execute("UPDATE stored_objects SET content_hash_algorithm='Sha256',content_hash=? WHERE object_id='object'",(DIGEST,))
        self.assertEqual((32,),db.execute("SELECT length(content_hash) FROM stored_objects WHERE object_id='object'").fetchone())
        db.close()

    def test_upgraded_database_does_not_need_full_fingerprint_duplicate(self):
        db=fixture(); migrate(db)
        self.assertEqual((16,),db.execute("SELECT length(content_hash) FROM stored_objects WHERE object_id='object'").fetchone())
        self.assertEqual((32,),db.execute("SELECT length(checksum) FROM stored_objects WHERE object_id='object'").fetchone())
        db.close()

    def test_full_scan_accepts_only_recognized_fingerprints(self):
        query='''SELECT CASE WHEN ?='Sha256_128' AND length(?)=16 THEN ?
                     WHEN ?='Sha256' AND length(?)=32 THEN ?
                     WHEN ?='Sha256' AND length(?)=32 THEN ? ELSE NULL END'''
        db=sqlite3.connect(':memory:')
        for alg,fp,checkalg,check,expected in [
            ('Sha256_128',DIGEST[:16],'None',None,DIGEST[:16]),
            ('Sha256',DIGEST,'None',None,DIGEST),
            ('unknown',DIGEST[:16],'None',None,None),
            ('Sha256',DIGEST[:16],'None',None,None),
            (None,None,'Sha256',DIGEST,DIGEST),
            ('unknown',DIGEST[:16],'Sha256',DIGEST,DIGEST)]:
            with self.subTest(alg=alg,checkalg=checkalg):
                self.assertEqual((expected,),db.execute(query,(alg,fp,fp,alg,fp,fp,checkalg,check,check)).fetchone())
        db.close()


if __name__ == '__main__':
    print('SQLite', sqlite3.sqlite_version, '| migration statements', len(STATEMENTS))
    unittest.main(verbosity=2)
