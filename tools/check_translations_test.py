"""Tests of check_translations.py's rule on the game's text widgets in the mod's windows (game_widgets).

    py -X utf8 tools/check_translations_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_translations as ct  # noqa: E402


def lua(path, text):
    return (path, text.split('\n'))


class GameWidgets(unittest.TestCase):
    def test_each_widget_is_found_in_code(self):
        found = ct.game_widgets([lua(os.path.join('client', 'OperationAcorn', 'Trade', 'Tab.lua'), '\n'.join([
            'local a = ISRichTextPanel:new(0, 0, 1, 1)',
            'local b = ISButton:new(0, 0, 1, 1, "x")',
            'local c = ISComboBox:new(0, 0, 1, 1)',
            'local d = ISModalDialog:new(0, 0, 1, 1, "t", true)',
            'local e = ISLabel:new(0, 0, 10, "t", 1, 1, 1, 1)',
            'require "ISUI/ISRichTextPanel"',
        ]))])
        self.assertEqual([(n, w) for _, n, w in found], [
            (1, 'ISRichTextPanel'), (2, 'ISButton:new'), (3, 'ISComboBox'), (4, 'ISModalDialog'), (5, 'ISLabel:new'),
            (6, 'ISRichTextPanel')])

    def test_comments_derived_classes_and_marked_lines_pass(self):
        found = ct.game_widgets([lua(os.path.join('client', 'OperationAcorn', 'Story', 'View.lua'), '\n'.join([
            '-- the game\'s ISRichTextPanel draws in its font',
            'local o = ISButton.new(self, x, y, w, h, title)',
            'OAMButton = ISButton:derive("OAMButton")',
            'local m = ISModalDialog:new(0, 0, 1, 1, "t", true) -- oa-widget: ok (a test of the mark)',
            '-- oa-widget: ok (the line under the mark)',
            'local l = ISLabel:new(0, 0, 10, "t", 1, 1, 1, 1)',
            'local x = MyISButton:newer()',
        ]))])
        self.assertEqual(found, [])

    def test_excluded_files_pass(self):
        for name in ('ItemTip.lua', 'Appraisal.lua', 'ContextMenu.lua'):
            found = ct.game_widgets([lua(os.path.join('client', 'OperationAcorn', 'Trade', name),
                                         'local b = ISButton:new(0, 0, 1, 1, "x")')])
            self.assertEqual(found, [], name)

    def test_the_mods_windows_are_clean(self):
        self.assertEqual(ct.game_widgets(ct.window_files()), [])


if __name__ == '__main__':
    unittest.main()
