#!/usr/bin/env python3
"""Regression and failure-injection tests for the offline documentation checker."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('documentation_checker', HERE/'check-documentation.py')
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)
C = CHECKER


class ParserTests(unittest.TestCase):
    def test_inline_html_image_and_reference_links(self):
        text = '''# Heading
[page](guide.md#start "Title") ![icon](icon.svg)
<a href='other.md'>Other</a><img src="image.png" />
[Read][ref] [REF][] [ref]
[ref]: <folder/some page.md> 'Reference title'
'''
        doc = C.Document.parse(text)
        self.assertCountEqual(['guide.md#start', 'icon.svg', 'other.md', 'image.png',
                               'folder/some page.md', 'folder/some page.md', 'folder/some page.md'],
                              [link.target for link in doc.links])
        self.assertIn('heading', doc.anchors)

    def test_code_comments_and_escaped_brackets_are_not_links(self):
        text = '''# Live
`[inline](missing.md)` ``[inline ` nested](missing.md)``
<!-- [comment](missing.md) <a href="missing.md"></a> -->
```md
# Not an anchor
[example](missing.md)
```
~~~
[other](missing.md)
~~~
\\[escaped](missing.md)
[actual](live.md)
'''
        doc = C.Document.parse(text)
        self.assertEqual(['live.md'], [link.target for link in doc.links])
        self.assertEqual({'live'}, doc.anchors)
        self.assertEqual(12, doc.links[0].line)

    def test_heading_slug_unicode_formatting_and_duplicate_suffixes(self):
        text = '''# **사용 안내**: `file_name`
# **사용 안내**: `file_name`
# 사용 안내: file_name-1
# 使用说明 / 日本語
# A _word_ and [link](page.md) ###
Setext title
============
'''
        self.assertEqual({'사용-안내-file_name', '사용-안내-file_name-1',
                          '사용-안내-file_name-1-1', '使用说明--日本語',
                          'a-word-and-link', 'setext-title'}, C.heading_ids(text))

    def test_explicit_id_and_legacy_name_anchors(self):
        doc = C.Document.parse('<a id="stable"></a>\n<a name="old"></a>\n## Renamed heading\n')
        self.assertEqual({'stable', 'old'}, doc.explicit)
        self.assertEqual({'stable', 'old', 'renamed-heading'}, doc.anchors)

    def test_nested_and_escaped_parentheses_spaces_and_titles(self):
        doc = C.Document.parse(r'''[one](folder/a(b).md) [two](folder/a\(b\).md)
[three](<folder/a b.md> "title (details)") [four](folder/a\ b.md)
''')
        self.assertEqual(['folder/a(b).md', 'folder/a(b).md', 'folder/a b.md', 'folder/a b.md'],
                         [link.target for link in doc.links])

    def test_html_entities_and_reference_label_whitespace(self):
        doc = C.Document.parse('[label][A   b]\n[A b]: page.md?x=1&amp;y=2\n')
        self.assertEqual('page.md?x=1&y=2', doc.links[0].target)

    def test_unclosed_code_fence_is_an_error(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Unclosed fenced'):
            C.Document.parse('```md\n[example](file.md)\n')

    def test_longer_outer_fence_does_not_end_at_shorter_inner_fence(self):
        doc = C.Document.parse('````md\n```\n[example](missing.md)\n```\n````\n[real](ok.md)')
        self.assertEqual(['ok.md'], [link.target for link in doc.links])

    def test_unclosed_link_is_an_error(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Unclosed link'):
            C.Document.parse('[text](page.md')

    def test_undefined_explicit_reference_is_an_error(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Undefined reference'):
            C.Document.parse('[text][missing]')

    def test_duplicate_reference_definition_is_an_error(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Duplicate reference'):
            C.Document.parse('[name]: first.md\n[NAME]: second.md\n')

    def test_duplicate_explicit_anchor_is_an_error(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Duplicate explicit'):
            C.Document.parse('<a id="same"></a>\n<div id="same"></div>')


class PathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pz-doc-links-')
        self.root = Path(self.temp.name).resolve()
        self.source = self.root/'README.md'
        self.source.write_text('# Home\n', encoding='utf-8')
        (self.root/'docs').mkdir()
        (self.root/'docs/Page.md').write_text('# 제목\n\n<a id="stable"></a>\n', encoding='utf-8')
        (self.root/'docs/a(b) file.md').write_text('# Title\n', encoding='utf-8')
        (self.root/'code.cs').write_text('line1\nline2\nline3\n', encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def validate(self, target):
        return C.validate_link(self.root, self.source, C.Link(target, 1), {})

    def test_valid_relative_root_unicode_and_explicit_anchors(self):
        self.assertEqual(self.root/'docs/Page.md', self.validate('docs/Page.md#%EC%A0%9C%EB%AA%A9'))
        self.assertEqual(self.root/'docs/Page.md', self.validate('/docs/Page.md#stable'))
        self.assertEqual(self.source, self.validate('#home'))

    def test_directory_link_and_percent_encoded_filename(self):
        self.assertEqual(self.root/'docs', self.validate('docs/'))
        self.assertEqual(self.root/'docs/a(b) file.md', self.validate('docs/a(b)%20file.md'))

    def test_broken_target_is_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Missing target'):
            self.validate('docs/missing.md')

    def test_wrong_case_is_rejected_on_windows_too(self):
        with self.assertRaisesRegex(C.DocumentationError, 'wrong case'):
            self.validate('docs/page.md')
        with self.assertRaisesRegex(C.DocumentationError, 'wrong case'):
            self.validate('Docs/Page.md')

    def test_missing_anchor_is_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Missing section'):
            self.validate('docs/Page.md#not-there')

    def test_empty_destination_is_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'Empty link'):
            self.validate('')

    def test_repository_escape_is_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'escapes repository'):
            self.validate('../outside.md')

    def test_backslashes_and_file_uri_are_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'forward slashes'):
            self.validate(r'docs\Page.md')
        with self.assertRaisesRegex(C.DocumentationError, 'Unsupported'):
            self.validate('file:///C:/private/guide.md')

    def test_valid_source_line_fragments(self):
        self.assertEqual(self.root/'code.cs', self.validate('code.cs#L1-L3'))
        self.assertEqual(self.root/'code.cs', self.validate('code.cs#L2'))

    def test_invalid_source_line_fragments_are_rejected(self):
        for fragment in ('L0', 'L4', 'L3-L1', 'not-an-anchor'):
            with self.subTest(fragment=fragment), self.assertRaises(C.DocumentationError):
                self.validate('code.cs#'+fragment)

    def test_external_urls_are_checked_syntactically_not_requested(self):
        for target in ('https://example.invalid/unavailable', 'http://example.invalid', 'mailto:test@example.invalid'):
            self.assertIsNone(self.validate(target))
        for target in ('https:///missing-host', 'javascript:alert(1)', '//example.invalid/path'):
            with self.subTest(target=target), self.assertRaises(C.DocumentationError):
                self.validate(target)

    def test_traversal_inside_percent_encoding_is_rejected(self):
        with self.assertRaisesRegex(C.DocumentationError, 'escapes repository'):
            self.validate('%2E%2E/outside.md')


class RepositoryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = HERE.parent

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pz-doc-contract-')
        self.root = Path(self.temp.name).resolve()
        # Only copy files required by the offline checker, never a user repository or .git.
        for folder in ('docs', 'src', 'tests', 'scripts', 'config', 'build', '.github'):
            shutil.copytree(self.repo/folder, self.root/folder,
                            ignore=shutil.ignore_patterns('bin', 'obj', '__pycache__'))
        for name in ('README.md', 'THIRD_PARTY_NOTICES.md', 'global.json', 'PzTools.sln'):
            shutil.copy2(self.repo/name, self.root/name)

    def tearDown(self):
        self.temp.cleanup()

    def replace(self, name, old, new):
        path = self.root/name
        text = path.read_text(encoding='utf-8')
        self.assertIn(old, text)
        path.write_text(text.replace(old, new), encoding='utf-8')

    def remove_link(self, name, target):
        path = self.root/name
        text = path.read_text(encoding='utf-8')
        text, count = re.subn(r'\[([^\]\n]+)\]\(' + re.escape(target) + r'\)', r'\1', text)
        self.assertGreater(count, 0, f'No Markdown link to {target} in {name}')
        path.write_text(text, encoding='utf-8')

    def test_real_documentation_passes(self):
        result = C.check(self.root)
        self.assertEqual(1, result['guides'])
        self.assertEqual(10, result['topics_per_guide'])
        self.assertGreater(result['local_links'], len(C.GUIDE_REFERENCES))

    def test_deleted_root_guide_is_rejected(self):
        (self.root/'README.md').unlink()
        with self.assertRaises(C.DocumentationError):
            C.check(self.root)

    def test_missing_guide_topic_is_rejected(self):
        self.replace('README.md', '<a id="game-saving"></a>', '<a id="removed"></a>')
        with self.assertRaisesRegex(C.DocumentationError, 'missing guide topics'):
            C.check(self.root)

    def test_missing_direct_reference_is_rejected(self):
        self.remove_link('README.md', 'docs/repository-housekeeping.md')
        with self.assertRaisesRegex(C.DocumentationError, 'missing direct reference'):
            C.check(self.root)

    def test_guide_section_containing_only_a_link_is_rejected(self):
        text = (self.root/'README.md').read_text(encoding='utf-8')
        anchor = '<a id="troubleshooting"></a>'
        start = text.index(anchor) + len(anchor)
        end = text.index('<a id="building"></a>', start)
        (self.root/'README.md').write_text(text[:start]+'\n## Troubleshooting\n\n[Documentation](docs/README.md)\n\n'+text[end:], encoding='utf-8')
        with self.assertRaisesRegex(C.DocumentationError, 'has no explanation'):
            C.check(self.root)

    def test_reference_missing_from_index_is_rejected(self):
        (self.root/'docs/new-reference.md').write_text('# New\n\n[Index](README.md)\n', encoding='utf-8')
        with self.assertRaisesRegex(C.DocumentationError, 'Documents missing from index'):
            C.check(self.root)

    def test_reference_without_backlink_is_rejected(self):
        self.remove_link('docs/cli.md', 'README.md')
        with self.assertRaisesRegex(C.DocumentationError, 'missing index backlink'):
            C.check(self.root)

    def test_broken_build_command_is_rejected(self):
        self.replace('README.md', 'dotnet build PzTools.sln -c Release', 'dotnet build missing.sln -c Release')
        with self.assertRaisesRegex(C.DocumentationError, 'missing technical instruction'):
            C.check(self.root)

    def test_missing_runtime_link_is_rejected(self):
        self.remove_link('README.md', 'https://dotnet.microsoft.com/en-us/download/dotnet/10.0')
        with self.assertRaisesRegex(C.DocumentationError, 'missing runtime, download or support'):
            C.check(self.root)

    def test_unclosed_document_code_block_is_rejected(self):
        path = self.root/'docs/cli.md'
        path.write_text(path.read_text(encoding='utf-8')+'\n~~~md\n', encoding='utf-8')
        with self.assertRaisesRegex(C.DocumentationError, 'Unclosed fenced'):
            C.check(self.root)

    def test_ui_language_catalog_contents_do_not_control_documentation(self):
        path = self.root/'src/PzTools.Process.Contracts/Localization/languages.tsv'
        path.write_text('The UI catalog has its own validation.\n', encoding='utf-8')
        self.assertEqual(1, C.check(self.root)['guides'])

    def test_localized_readme_guides_are_rejected(self):
        for tag in ('ko-KR', 'en-US', 'xx-XX'):
            with self.subTest(tag=tag):
                page = self.root/f'docs/{tag}/README.md'
                page.parent.mkdir(exist_ok=True)
                page.write_text('# Parallel user guide\n', encoding='utf-8')
                with self.assertRaisesRegex(C.DocumentationError, 'Localized README guides are not supported'):
                    C.check(self.root)
                page.unlink()


class IndependentEnglishDocumentationTests(unittest.TestCase):
    def test_single_english_guide_passes_without_any_ui_catalog_or_resources(self):
        with tempfile.TemporaryDirectory(prefix='pz-english-docs-') as folder:
            root = Path(folder).resolve()
            (root/'docs').mkdir()
            reference_paths = [path for path in C.GUIDE_REFERENCES if path.startswith('docs/') and path != 'docs/README.md']
            for path in reference_paths:
                (root/path).write_text('# Reference\n\n[Documentation index](README.md)\n', encoding='utf-8')
            (root/'THIRD_PARTY_NOTICES.md').write_text('# Third-party notices\n', encoding='utf-8')
            index_links = ['[User guide](../README.md)', '[Notices](../THIRD_PARTY_NOTICES.md)']
            index_links.extend(f'[Reference]({Path(path).name})' for path in reference_paths)
            (root/'docs/README.md').write_text('# Documentation\n\n'+'\n'.join(index_links)+'\n', encoding='utf-8')
            sections = [f'<a id="{anchor}"></a>\n## Topic {number}\n\nEnglish operating instructions.\n'
                        for number, anchor in enumerate(C.GUIDE_SECTIONS, start=1)]
            guide = '# PZ Tools\n\n'+'\n'.join(sections)
            guide += '\n'+'\n'.join(f'[Reference]({path})' for path in C.GUIDE_REFERENCES)+'\n'
            guide += '\n'+'\n'.join(C.GUIDE_FACT_TOKENS)+'\n'
            guide += '\n```powershell\n'+'\n'.join(C.BUILD_COMMANDS)+'\n```\n'
            guide += '\n[Releases](https://github.com/isxcsm/pz-tools/releases)\n'
            guide += '[Support](https://github.com/isxcsm/pz-tools/issues)\n'
            guide += '[Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)\n'
            (root/'README.md').write_text(guide, encoding='utf-8')

            self.assertFalse((root/'src').exists())
            result = C.check(root)
            self.assertEqual(1, result['guides'])
            self.assertEqual(10, result['topics_per_guide'])

            # Independence from UI configuration does not exempt authored links from validation.
            guide += '\n[UI catalog](src/PzTools.Process.Contracts/Localization/languages.tsv)\n'
            (root/'README.md').write_text(guide, encoding='utf-8')
            with self.assertRaisesRegex(C.DocumentationError, 'Missing target'):
                C.check(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
