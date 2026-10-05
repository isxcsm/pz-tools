"""SQL read from the C# repository sources, for the offline SQLite checks and measurements.

Stdlib only. Scripts import it as a sibling module: Python puts a script's own folder on sys.path,
so `python scripts/<name>.py` finds it from any working directory.

Fixtures are the production schema itself, and statements are picked by content or constant name,
never by position, so a reordered file or a new constant fails loudly instead of running other SQL.
"""
from __future__ import annotations

from pathlib import Path
import re
import sqlite3
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'src/PzTools.Backup.Storage/Repository/'
_LITERAL = re.compile(r'(?:const string (\w+)\s*=\s*)?(\$*)"""(.*?)"""', re.S)


def source(name: str, ref: str | None = None) -> str:
    """A repository source file from this checkout, or from git commit `ref`."""
    if ref:
        return subprocess.check_output(['git', 'show', f'{ref}:{REPOSITORY}{name}'], cwd=ROOT).decode('utf-8-sig')
    return (ROOT / REPOSITORY / name).read_text(encoding='utf-8-sig')


def _literals(text: str):
    for match in _LITERAL.finditer(text):
        yield match.group(1), len(match.group(2)), textwrap.dedent(match.group(3)).strip()


def blocks(text: str) -> list[str]:
    """Every raw string literal (\"\"\"...\"\"\") in a C# source, dedented."""
    return [sql for _, _, sql in _literals(text)]


def block(text: str, marker: str, label: str = 'source') -> str:
    """The one raw string literal containing `marker`."""
    found = [sql for sql in blocks(text) if marker in sql]
    if len(found) != 1:
        raise SystemExit(f'{label}: expected one SQL block containing {marker!r}, found {len(found)}')
    return found[0]


def constant(text: str, name: str, label: str = 'source') -> str:
    """The raw string literal assigned to `const string name`."""
    found = [sql for constant_name, _, sql in _literals(text) if constant_name == name]
    if len(found) != 1:
        raise SystemExit(f'{label}: expected one SQL constant {name}, found {len(found)}')
    return found[0]


def schema(text: str, label: str = 'RepositorySchema.cs') -> str:
    """The SQL a fresh repository runs, from RepositorySchema.cs at any revision.

    That is every migration literal, in order, with its {{Name}} parts taken from the same file's
    constants. Constants are only parts: a current file defines tables shared with the upgrade there.
    """
    section = text.split('internal static class RepositoryMigrationRunner')[0]
    literals = list(_literals(section))
    constants = {name: sql for name, _, sql in literals if name}
    migrations = []
    for name, dollars, sql in literals:
        if name:
            continue
        if dollars:
            # In a $$"""...""" literal a placeholder has as many braces as the literal has dollars.
            placeholder = re.compile(r'\{' * dollars + r'(\w+)' + r'\}' * dollars)

            def resolve(match):
                if match.group(1) not in constants:
                    raise SystemExit(f'{label}: no constant {match.group(1)} for the migration')
                return constants[match.group(1)]
            sql = placeholder.sub(resolve, sql)
        migrations.append(sql)
    if not migrations or not any('CREATE TABLE sources' in sql for sql in migrations):
        raise SystemExit(f'{label}: no fresh-repository migration found')
    return '\n\n'.join(migrations)


def add_run(db: sqlite3.Connection, run_index: int, source_id: int, started_utc: str,
            completed_utc: str | None = None, status: str = 'Succeeded') -> None:
    """The one run row a revision (and a pack) references, in whichever layout the schema has.

    Schemas up to 5 keep backup runs in `runs`; schema 6 keeps one history in `workflow_runs`.
    """
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='runs'").fetchone():
        db.execute('INSERT INTO runs(run_index,source_id,status,started_utc,completed_utc) VALUES(?,?,?,?,?)',
                   (run_index, source_id, status, started_utc, completed_utc))
    else:
        db.execute('INSERT INTO workflow_runs(run_index,pipeline,source_id,owner_component,status,started_utc,completed_utc) '
                   "VALUES(?,'backup',?,'backup-worker',?,?,?)",
                   (run_index, source_id, status, started_utc, completed_utc))
