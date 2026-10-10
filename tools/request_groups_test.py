"""Tests of request_groups.py's availability profile: how the ways a kind is come by add up, how a recipe's making is
judged, how a group's kinds combine, and the bands by rank (the same rule as Requests.rank).

    py -X utf8 tools/request_groups_test.py
"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import request_groups as rg  # noqa: E402


def recipe(name, inputs, outputs, tools=(), skill=0, learn=False):
    """inputs: [[(type, count)...] a slot], outputs: [(type, count, mapped inputs or None)]."""
    return {'name': name, 'inputs': [list(s) for s in inputs], 'tools': [list(s) for s in tools],
            'outputs': list(outputs), 'skill': skill, 'learn': learn, 'tags_used': set()}


class Combine(unittest.TestCase):
    def test_the_ways_and_the_kinds_add_as_rates(self):
        # A rate per way: the chance of none in a week is the product of each way's, so the rates add.
        rates = [0.3, 1.2, 0.05]
        p = [1 - math.exp(-r) for r in rates]
        anyone = 1 - math.prod(1 - x for x in p)
        self.assertAlmostEqual(anyone, 1 - math.exp(-sum(rates)), places=12)

    def test_a_group_is_the_sum_of_its_kinds(self):
        rate = {'A': {'loot': 2.0}, 'B': {'loot': 0.5, 'forage': 0.25}, 'C': {}}
        self.assertAlmostEqual(rg.group_rate(['A', 'B', 'C'], rate, {}), 2.75)
        self.assertGreater(rg.group_rate(['A', 'B'], rate, {}), rg.group_rate(['A'], rate, {}),
                           'a family turns up more than any one kind of it')

    def test_making_one_kind_from_another_of_the_group_adds_nothing(self):
        # Ankle socks cut from long socks: the group had the socks already.
        rate = {'Long': {'loot': 3.0}, 'Ankle': {'loot': 1.0, 'craft': 3.0}, 'Kiln': {'craft': 20.0}}
        shorten = recipe('ShortenSocks', [[('Long', 1.0)]], [('Ankle', 1.0, None)])
        made = {'Ankle': ('ShortenSocks', {'Long'}, shorten), 'Kiln': ('MakeWoodCharcoal', {'Base.Log'}, None)}
        self.assertAlmostEqual(rg.group_rate(['Long', 'Ankle'], rate, made), 4.0)
        self.assertAlmostEqual(rg.group_rate(['Ankle'], rate, made), 4.0, msg='alone, the long socks are outside')
        self.assertAlmostEqual(rg.group_rate(['Kiln'], rate, made), 20.0, msg='logs are no charcoal')

    def test_a_kind_made_from_any_of_several_counts_those_outside_the_group(self):
        # A fillet of any fish: the group holds salmon and fillets; the bass caught outside it still make fillets.
        fillet = recipe('Fillet', [[('Salmon', 1.0), ('Bass', 1.0)]], [('Fillet', 2.0, None)])
        rate = {'Salmon': {'loot': 1.0}, 'Bass': {'fish': 0.5}, 'Fillet': {'loot': 0.25, 'craft': 3.0}}
        made = {'Fillet': ('Fillet', {'Salmon', 'Bass'}, fillet)}
        self.assertAlmostEqual(rg.group_rate(['Salmon', 'Fillet'], rate, made), 1.0 + 0.25 + 0.5 * 2)
        ways = rg.group_ways(['Salmon', 'Fillet'], rate, made)
        self.assertAlmostEqual(ways['craft'], 1.0)


class Craft(unittest.TestCase):
    def test_the_scarcest_input_sets_how_often_and_the_outputs_multiply(self):
        r = recipe('Kiln', [[('Log', 2.0)]], [('Charcoal', 12.0, None)])
        made = rg.craft_rates([r], {'Log': 1.0})
        self.assertAlmostEqual(made['Charcoal'][0], 1.0 / 2 * 12)
        two = recipe('Pair', [[('A', 1.0)], [('B', 1.0)]], [('AB', 1.0, None)])
        self.assertAlmostEqual(rg.craft_rates([two], {'A': 5.0, 'B': 0.5})['AB'][0], 0.5)

    def test_alternatives_of_a_slot_add_and_keep_their_own_count(self):
        r = recipe('Kiln', [[('Log', 2.0), ('Branch', 3.0)]], [('Charcoal', 12.0, None)])
        self.assertAlmostEqual(rg.craft_rates([r], {'Log': 0.2, 'Branch': 0.3})['Charcoal'][0], (0.1 + 0.1) * 12)

    def test_skill_learning_tools_and_the_cap(self):
        base = recipe('R', [[('In', 1.0)]], [('Out', 1.0, None)])
        hard = recipe('R', [[('In', 1.0)]], [('Out', 1.0, None)], skill=3, learn=True)
        self.assertAlmostEqual(rg.craft_rates([hard], {'In': 1.0})['Out'][0],
                               rg.SKILL_STEP ** 3 * rg.LEARN * rg.craft_rates([base], {'In': 1.0})['Out'][0])
        tooled = recipe('R', [[('In', 1.0)]], [('Out', 1.0, None)], tools=[[('Saw', 1.0)]])
        self.assertAlmostEqual(rg.craft_rates([tooled], {'In': 1.0, 'Saw': 0.5})['Out'][0],
                               1 - math.exp(-rg.TOOL_WEEKS * 0.5))
        self.assertNotIn('Out', rg.craft_rates([tooled], {'In': 1.0}), 'no saw, no making')
        self.assertEqual(rg.craft_rates([base], {'In': 1000.0})['Out'][0], rg.CRAFT_CAP)

    def test_a_mapped_output_comes_from_its_own_input(self):
        # Opening a packet of carrot seeds gives carrot seeds, not tomato seeds.
        r = recipe('Open', [[('CarrotPacket', 1.0), ('TomatoPacket', 1.0)]],
                   [('CarrotSeed', 5.0, {'CarrotPacket'}), ('TomatoSeed', 5.0, {'TomatoPacket'})])
        made = rg.craft_rates([r], {'CarrotPacket': 0.2, 'TomatoPacket': 0.0})
        self.assertAlmostEqual(made['CarrotSeed'][0], 1.0)
        self.assertNotIn('TomatoSeed', made)

    def test_a_recipe_that_takes_back_what_it_makes_gives_nothing_new(self):
        r = recipe('Repair', [[('Broken', 1.0), ('Glue', 1.0)]], [('Broken', 1.0, None)])
        self.assertEqual(rg.craft_rates([r], {'Broken': 1.0, 'Glue': 1.0}), {})


class Bands(unittest.TestCase):
    RULES = {'share': {'common': 0.5, 'normal': 0.35},
             'bands': {'common': {'qtyMin': 5, 'qtyMax': 20}, 'normal': {'qtyMin': 3, 'qtyMax': 9},
                       'rare': {'qtyMin': 2, 'qtyMax': 5}}, 'curve': 2.0}

    def groups(self, scores):
        return {'g%02d' % i: {'id': 'g%02d' % i, 'score': s} for i, s in enumerate(scores)}

    def test_by_rank_half_common_35_percent_normal_the_rest_rare(self):
        groups = self.groups([100 - i for i in range(40)])
        rg.rank_bands(groups, self.RULES)
        bands = [groups['g%02d' % i]['band'] for i in range(40)]
        self.assertEqual(bands, ['common'] * 20 + ['normal'] * 14 + ['rare'] * 6)
        self.assertEqual(groups['g00']['qty'], 20)
        self.assertEqual(groups['g19']['qty'], 5)
        self.assertEqual(groups['g20']['qty'], 9)
        self.assertEqual(groups['g39']['qty'], 2)
        self.assertEqual(groups['g09']['qty'], int(5 + 15 * (10 / 19) ** 2 + 0.5), 'as Requests.rank')

    def test_an_equal_score_takes_the_first_ones_band(self):
        groups = self.groups([5, 5, 1, 1, 1, 1])
        rg.rank_bands(groups, self.RULES)
        self.assertEqual({g['band'] for g in groups.values()}, {'common'})
        self.assertEqual(groups['g02']['qty'], groups['g05']['qty'])


if __name__ == '__main__':
    unittest.main()
