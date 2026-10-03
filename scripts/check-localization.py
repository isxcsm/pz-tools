#!/usr/bin/env python3
"""Check all app locale resources and shared JVM/C# notices without loading user data.

This validates structure and message contracts, not native-speaker quality or UI layout.
Windows localization tests additionally exercise .NET CompositeFormat and settings.
"""
from __future__ import annotations
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
STRINGS = ROOT / 'src/PzTools.App/Strings'
CATALOG = ROOT / 'src/PzTools.Process.Contracts/Localization/languages.tsv'
TOKEN = re.compile(r'\{\d+[^{}]*\}')


def resources(tag: str) -> dict[str, str]:
    rows = ET.parse(STRINGS / tag / 'Resources.resw').getroot().findall('data')
    names = [row.attrib['name'] for row in rows]
    if len(names) != len(set(names)):
        raise AssertionError(f'{tag}: duplicate resource keys')
    return {row.attrib['name']: row.findtext('value', '') for row in rows}


def main() -> None:
    languages = [line.split('\t') for line in CATALOG.read_text(encoding='utf-8').splitlines()]
    assert all(len(row) == 10 for row in languages), 'Catalog entries require ten fields'
    tags = [row[1] for row in languages]
    assert len(tags) == len(set(tags)), 'Duplicate language tags'
    assert set(tags) == {path.parent.name for path in STRINGS.glob('*/Resources.resw')}
    baseline = resources('en-US')
    keys = set(baseline)
    # Only literal calls; dynamic families are covered by the C# tests and key parity.
    references: set[str] = set()
    for path in (ROOT / 'src/PzTools.App').glob('*.cs'):
        references.update(re.findall(r'Localizer\.(?:Get|Format)\("([^"\n]+)"', path.read_text(encoding='utf-8-sig')))
    assert references <= keys, f'Missing literal references: {references-keys}'
    mapper = (ROOT / 'src/PzTools.App.Core/UserFacingErrorCatalog.cs').read_text(encoding='utf-8')
    diagnostics = set(re.findall(r'"((?:OperationError|RecoveryError)\.[A-Za-z]+|OperationCancelled)"', mapper))
    assert diagnostics <= keys, f'Missing error messages: {diagnostics-keys}'
    values_checked = 0
    for row in languages:
        tag = row[1]
        localized = resources(tag)
        assert set(localized) == keys, f'{tag}: key set differs from English'
        for key, value in localized.items():
            assert value.strip(), f'{tag}/{key}: empty value'
            assert not any(char in value for char in ('\ufffd', '⟪', '⟦')), f'{tag}/{key}: damaged text'
            assert sorted(TOKEN.findall(value)) == sorted(TOKEN.findall(baseline[key])), f'{tag}/{key}: format arguments differ'
            values_checked += 1
        assert localized['AutomaticSaveLabel'] == row[5], f'{tag}: automatic backup badge disagrees with catalog'
        assert localized['ManualBackupNameFormat'] == row[4] + ' {0:N0}'
        assert localized['AutomaticBackupNameFormat'] == row[5] + ' {0:N0}'
        assert TOKEN.findall(row[6]) == ['{0}'], f'{tag}: game countdown parameter differs'
        assert all(row[index].strip() and not TOKEN.findall(row[index]) for index in (7, 8, 9)), f'{tag}: missing notice or unexpected parameters'
        assert localized['SettingEnabled'] != localized['SettingDisabled']
    print(f'PASS: {len(tags)} languages, {len(keys)} keys, {values_checked} values; '
          f'{len(references)} literal UI keys and {len(diagnostics)} error keys resolve; '
          'shared game notices and backup labels agree.')


if __name__ == '__main__':
    main()
