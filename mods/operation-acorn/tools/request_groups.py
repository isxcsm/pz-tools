"""The weekly request list's table (NUMBERS 2): what the team asks for, grouped one level above the item type, and how
easy each group is to come by, worked out from the game's own files. Writes
OperationAcorn/42/media/lua/shared/OperationAcorn/Economy/RequestGroups.lua (the mod loads it; do not edit it by hand)
and, with --report, a plain text summary next to it in the scratch folder given (the counts, the groups, what was left out).

    py -X utf8 tools/request_groups.py                  writes the Lua table
    py -X utf8 tools/request_groups.py --report DIR     also writes DIR/request-groups.txt

What it reads (B42, the installed game):
- the item scripts (media/scripts/**.txt): display category, item type, weight, tags;
- the item names (Translate/EN and KO ItemName.json): variants are the names whose words before ' [' are the same,
  in Korean, or in English when the kinds are of one display category and their Korean names are near each other;
- the loot tables (media/lua/server/Items: Distributions.lua, ProceduralDistributions.lua and the tables they name)
  and how many rooms of each name the maps have (media/maps/*/*.lotheader), for how often a thing is found;
- craftRecipe (inputs, outputs, SkillRequired, NeedToBeLearn), the foraging categories, the farm crops, the animal
  parts, fishing and trapping, and the parts vehicles are built from: the other ways to come by a thing;
- the mod's own Categories.lua: what the delivery boxes take (the request candidates are taken things only).

The rules (written out in mockups/terminal/request-groups-report.md):
- Candidates: the kinds the house rooms' loot hands out and the boxes take (not cash), less the left-out kinds (keys,
  maps, specimens, containers posing as items, personal papers, newspapers, bulk cartons, trash: EXCLUDE below). A
  group may also take kinds no house hands out (the kiln's charcoal).
- A group is, in this order: a family (FAMILIES: one ordinary noun above the kinds, "any can", "any hat", from the
  game's fields first, then the ids and names, then a list by hand; the book families were decided with the user;
  mockups/terminal/request-families.md has the table and what was kept apart), a narrow tag the recipes use
  for "any of these" (base:charcoal; TAG_MAX kinds at most, of one display category, not a BROAD_TAGS property), the
  variants (union-find: the Korean name before ' [' is the same, spaces and stray brackets aside; or the English name
  is the same, of one display category, the Korean names being near: the words of one inside the other), and a few
  groups by hand (MANUAL: one appliance of several brands). Everything else is a group of its own. Groups the list
  would show under the same Korean name are then one group, so a week never shows a name twice (one that would show
  a family's name joins the family).
  The ids of the name groups ('n:...') continue the previous table (this file, as the last run wrote it): a group
  keeps the id of the old group most of its kinds came from, and an old id that goes away is kept in the row that
  took over (`was`), so a saved list is moved to the new group (Requests.keyOf).
- How easy a group is (the availability profile, mockups/terminal/request-availability.md): each kind has a rate, how
  many of it an ordinary week turns up (WEEK), the sum of every way the game gives it: looting (the whole map's
  expected count, by how many rooms of each name the maps have, each container a room's list names once (a plank
  stash in one building of a hundred), how likely each container picks each list, rolls x weight/100), the cars
  (VehicleDistributions by VehicleZoneDistribution's spawn chances, the parking zones weighed by their area; their
  parts through the vehicle scripts' templates), foraging (category and kind weights per zone, the zones by area),
  the farm (the crops' harvest a week, if the seed is had), butchering and kept animals, fishing and trapping, and
  making (craftRecipe, one level deep: the scarcest input, skill, learning, tools). A group's rate is the sum of its
  kinds' (the chance to come by any one of them is 1 - exp(-rate)), less what a kind is made from another kind of the
  same group. Requests.lua ranks the groups by it into the bands (Requests.rank; rank_bands here, for the report).
"""
import glob
import json
import math
import os
import re
import struct
import sys
import zlib
from collections import Counter, defaultdict

GAME = r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid'
MEDIA = os.path.join(GAME, 'media')
HERE = os.path.dirname(os.path.abspath(__file__))
MOD_LUA = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media', 'lua')
OUT = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'RequestGroups.lua')
CATEGORIES = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Categories.lua')
REQUESTS = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Requests.lua')
VALUE = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Value.lua')
UI_KO = os.path.join(MOD_LUA, 'shared', 'Translate', 'KO', 'IG_UI.json')


# The families: one level above the kind, what the research team would write on a requisition as one ordinary noun
# ("any can", "any hat"; not "food" or "clothing"). A family takes every member its rule names (taken and not left
# out), whatever its other tags; the first rule that names a kind has it, so the narrow rules come before the wide ones.
# A rule reads, in this order of preference, the game's own fields (DisplayCategory, CannedFood, BodyLocation,
# FoodType, the fluid a bottle holds, tags, ItemType), then the item ids or names, then a list by hand. Each row:
# (id, where the rule comes from: 'field' / 'pattern' / 'hand', test(item) -> bool). The name is the translation key
# IGUI_OA_ReqGroup_<id> (KO and EN IG_UI.json); the reasons for each rule and what was kept apart are written out in
# mockups/terminal/request-families.md. The book families were decided with the user: HollowBook is a container and
# newspapers are left out (EXCLUDE); the books are the hardcovers, the softcovers and the leather-bound ones.
FARM = set()                       # the farm crops (farm_items), read before the families are made


def _f(it, key):
    return it['f'].get(key, '')


def _fluid(it):
    return _f(it, 'fluid').split(':')[0]


def _ids(*names):
    names = set(names)
    return lambda it: it['name'] in names


def _plain_ko(it):
    return strip_variant(it.get('ko', ''))


# Kinds made from whatever is at hand (wrapped rags, tarp, garbage bags, raw hide, bone, scrap): a family of clothes or
# gear never takes them, or a weekly line could be filled from a pile of rags.
MAKESHIFT = re.compile(r'(Wrap|Garbage|Tarp|Rag(?![a-z])|Twine|Crude|Newspaper|TinFoil|Scrap|Bone|Hide|SheepSkin'
                       r'|LeatherStrip|MetalHelmet|MetalArmour|DuctTape|Broken|Spike)')
# Food that is no longer the thing bought: opened, dried, cooked into something, sliced, a seed, a dough or a dish.
NOT_FRESH = re.compile(r'(Open|Dried|Canned|Fried|Seed|Frozen|Slice|Smashed|Rotten|Burnt|Cooked|Recipe|Dough'
                       r'|Fingers|Nugget|Jerky|Dumpling|Calamari|Raw|Prep|tray)')


def _fresh(it):
    return not NOT_FRESH.search(it['name']) and _f(it, 'packaged') != 'true'


def _wear(it, *locs):
    """Clothes at one of the body locations, of the clothes and accessories (not protective gear), not makeshift."""
    return it['body'] in locs and it['dc'] in ('Clothing', 'Accessory', 'Memento') and not MAKESHIFT.search(it['name'])


HAT_NOT = re.compile(r'(Bandana|Shemagh|EarMuff|Sweatband|HeadMirror|HeadSack|Antlers|Joke|GoldStar|Ears|WeddingVeil'
                     r'|Hat_Spiffo$|Cowboy_Plastic|HatDebug|SurgicalCap|DeerHeadress|Helmet|ArmyWWII)')
SPIRITS = {'Brandy', 'Gin', 'Rum', 'Scotch', 'Tequila', 'Vodka', 'Whiskey', 'CoffeeLiqueur', 'Curacao'}
WINES = {'Wine', 'Champagne', 'Port', 'Sherry', 'Vermouth'}
SODAS = {'Cola', 'ColaDiet', 'GingerAle', 'SodaGrape', 'SodaStrewberry'}
HERBS = ('Basil', 'Chives', 'Cilantro', 'Oregano', 'Parsley', 'Rosemary', 'Sage', 'Thyme')

FAMILIES = [
    # Books (with the user).
    # A boxed set of five skill books (BookCarpentrySet) is a store's bundle, as the bulk cartons are: kept apart.
    # (The heavy kinds were kept out of the families while a group's price floor was its dearest member's worth; each
    # kind is paid its own worth now, and the families were left as they are.)
    ('skillbook', 'field', lambda it: it['dc'] == 'SkillBook' and not it['name'].endswith('Set')),
    # The empty seed packets are of this display category too: not reading, and made by opening a packet.
    ('recipemag', 'field', lambda it: it['dc'] == 'RecipeResource' and 'BagSeed' not in it['name']),
    ('books', 'field', lambda it: it['dc'] == 'Literature' and ({'base:hardcover', 'base:softcover', 'base:fancybook'}
                                                                 & it['tags'])),
    ('reading', 'field', lambda it: it['dc'] == 'Literature' and ({'base:magazine', 'base:picturebook'} & it['tags'])),
    # Food in tins and jars. A sealed tin is CannedFood that cannot be eaten yet (CantEat: it has to be opened); the
    # dog food tin is pet food, kept apart. The boxes of twelve tins are a store's stock, a family of their own. The
    # jars (base:preservedfood) are put up at home: no can opener, a jar and a lid back, canned from the garden.
    ('cans', 'field', lambda it: _f(it, 'cannedfood') == 'true' and (_f(it, 'canteat') == 'true'
                                                                     or _f(it, 'openingrecipe') != '')
     and it['name'] != 'Dogfood'),
    ('cannedbox', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].endswith('_Box')
     and re.match(r'(Canned|Tinned|TunaTin|MysteryCan|WaterRationCan)', it['name'])),
    ('jarred', 'field', lambda it: 'base:preservedfood' in it['tags']),
    # Frozen sweets and frozen bags.
    ('icecream', 'field', lambda it: 'base:goodfrozen' in it['tags']),
    ('frozen', 'pattern', lambda it: it['dc'] == 'Food' and (
        it['name'].startswith('Frozen_') or it['name'] in ('CornFrozen', 'MixedVegetables', 'Peas'))),
    # Drinks, by the fluid the bottle or can holds (opened bottles are not the thing bought).
    ('beer', 'field', lambda it: it['dc'] == 'Food' and _fluid(it) == 'Beer'),
    ('wine', 'field', lambda it: it['dc'] == 'Food' and _fluid(it) in WINES and not it['name'].endswith('Open')),
    ('spirits', 'field', lambda it: it['dc'] == 'Food' and _fluid(it) in SPIRITS),
    ('soda', 'field', lambda it: it['dc'] == 'Food' and _fluid(it) in SODAS),
    ('juice', 'field', lambda it: it['dc'] == 'Food' and _fluid(it).startswith('Juice')),
    ('milk', 'field', lambda it: it['dc'] == 'Food' and _fluid(it) in ('CowMilk', 'MilkChocolate')),
    # Snacks and sweets. Chocolate before candy: the bars are FoodType Candy too.
    ('chocolate', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].startswith('Chocolate')
     and it['name'] not in ('ChocolateChips', 'Chocolate_Candy')),
    ('candy', 'field', lambda it: it['dc'] == 'Food' and (it['food'] == 'Candy' or it['name'] == 'Lollipop')),
    ('snacks', 'hand', _ids('Crisps', 'Crisps2', 'Crisps3', 'Crisps4', 'TortillaChips', 'TortillaChipsBaked',
                            'Pretzel', 'PorkRinds', 'Popcorn', 'Crackers', 'GrahamCrackers')),
    ('pie', 'pattern', lambda it: it['dc'] == 'Food' and re.match(r'Pie($|[A-Z])', it['name'])
     and _fresh(it)),
    ('donut', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].startswith('Doughnut')),
    ('muffin', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].startswith('Muffin')),
    ('bread', 'field', lambda it: it['dc'] == 'Food' and (it['food'] == 'Bread' or it['name'] in (
        'BunsHamburger', 'BunsHotdog', 'Croissant')) and not re.search(r'(Slices|Dough|_single)', it['name'])),
    ('cheese', 'field', lambda it: 'base:cheese' in it['tags']),
    ('noodles', 'field', lambda it: it['dc'] == 'Food' and it['food'] == 'Pasta'),
    ('beans', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].startswith('Dried')
     and (it['food'] == 'Bean' or it['name'] in ('DriedLentils', 'DriedSplitPeas'))),
    # The kitchen herbs: those the game also sells dried as a seasoning (Seasoning_<herb>), fresh, dried or ground.
    ('herbs', 'field', lambda it: it['dc'] == 'Food' and re.match(r'(Seasoning_)?(%s)(Dried)?$' % '|'.join(HERBS),
                                                                  it['name'])),
    ('sauce', 'hand', _ids('Ketchup', 'Mustard', 'MayonnaiseFull', 'RemouladeFull', 'BBQSauce', 'Hotsauce',
                           'Soysauce', 'Dip_NachoCheese', 'Dip_Ranch', 'Dip_Salsa', 'Marinara', 'Gravy')),
    ('jam', 'pattern', lambda it: it['dc'] == 'Food' and it['name'].startswith('Jam')),
    ('spices', 'hand', _ids('Pepper', 'PowderedGarlic', 'PowderedOnion', 'Cinnamon', 'SeasoningSalt')),
    ('petfood', 'field', lambda it: it['dc'] == 'Food' and (it['food'] in ('CatFood', 'DogFood')
                                                            or it['name'] in ('Dogfood', 'CatTreats'))),
    # Fresh produce, meat and fish, by FoodType; fresh only.
    ('fruit', 'field', lambda it: it['dc'] == 'Food' and (it['food'] in ('Fruits', 'Citrus')
                                                          or it['name'] == 'Strewberrie') and _fresh(it)
     and it['name'] != 'Watermelon'),           # three kilos (kept apart while the price floor was the dearest's)
    ('vegetables', 'field', lambda it: it['dc'] == 'Food' and _fresh(it) and (
        (it['food'] in ('Vegetables', 'Greens', 'HotPepper') and (it['full'] in FARM or it.get('cand')))
        or it['name'] in ('Pumpkin', 'Squash', 'Garlic'))),
    ('meat', 'field', lambda it: it['dc'] == 'Food' and it['food'] in ('Beef', 'Meat', 'Poultry', 'Game', 'Venison')
     and _fresh(it) and not re.search(r'(Ham|Hotdog|Bacon)', it['name'])),
    ('sausage', 'field', lambda it: it['dc'] == 'Food' and it['food'] == 'Sausage' and _fresh(it)),
    ('fish', 'field', lambda it: it['dc'] == 'Food' and it['food'] == 'Fish' and _fresh(it)),
    ('seafood', 'field', lambda it: it['dc'] == 'Food' and (it['food'] == 'Seafood' or it['name'] == 'Mussels')
     and _fresh(it)),
    # Smoking and fire.
    ('tobacco', 'field', lambda it: {'base:smokable', 'base:tobacco', 'base:chewingtobacco'} & it['tags']
     and it['dc'] == 'Junk'),
    ('matches', 'pattern', lambda it: 'base:startfire' in it['tags'] and it['name'].startswith('Match')),
    # Clothes, by BodyLocation (and the id where one location holds two things).
    ('hats', 'field', lambda it: _wear(it, 'base:hat') and it['name'].startswith('Hat_')
     and not HAT_NOT.search(it['name'])),
    ('helmets', 'field', lambda it: it['dc'] in ('ProtectiveGear', 'Memento') and it['body'] in ('base:hat',
     'base:fullhat') and re.search(r'(Helmet|HardHat|Hat_Fireman|Hat_Army|Hat_SWAT)', it['name'])
     and not MAKESHIFT.search(it['name'])),
    ('glasses', 'field', lambda it: _wear(it, 'base:eyes') and it['dc'] == 'Accessory'
     and it['name'].startswith('Glasses') and not re.search(r'(Goggles|Monocle)', it['name'])),
    ('gloves', 'field', lambda it: _wear(it, 'base:hands') and it['name'].startswith('Gloves_')),
    ('shoes', 'field', lambda it: _wear(it, 'base:shoes')),
    ('socks', 'field', lambda it: _wear(it, 'base:socks')),
    ('stockings', 'field', lambda it: _wear(it, 'base:underwearextra1')),
    ('swimwear', 'field', lambda it: _wear(it, 'base:underwear') and not it['name'].startswith('BunnySuit')
     or it['name'].startswith('Briefs_SmallTrunks')),
    ('underwear', 'field', lambda it: _wear(it, 'base:underweartop', 'base:underwearbottom')),
    ('longjohns', 'field', lambda it: 'base:long_johns' in it['tags'] or it['name'] == 'LongJohns'),
    ('tshirts', 'field', lambda it: _wear(it, 'base:tshirt')),
    ('shirts', 'field', lambda it: _wear(it, 'base:shirt', 'base:shortsleeveshirt')),
    ('sweaters', 'field', lambda it: _wear(it, 'base:sweater') and it['name'].startswith('Jumper_')),
    ('jackets', 'field', lambda it: _wear(it, 'base:jacket', 'base:jacket_bulky', 'base:jacketsuit',
                                          'base:jackethat_bulky') and re.match(r'(Jacket|Suit_Jacket)', it['name'])),
    ('pants', 'field', lambda it: _wear(it, 'base:pants', 'base:pants_skinny')),
    ('shorts', 'field', lambda it: _wear(it, 'base:shortpants', 'base:shortsshort') and it['name'].startswith('Shorts_')
     and not re.search(r'(Football|Hockey)', it['name'])),
    ('dresses', 'field', lambda it: _wear(it, 'base:dress', 'base:longdress') and it['name'].startswith('Dress')
     and 'Negligee' not in it['name']),
    ('skirts', 'pattern', lambda it: it['dc'] == 'Clothing' and it['name'].startswith('Skirt_')
     and not MAKESHIFT.search(it['name'])),
    ('vests', 'field', lambda it: _wear(it, 'base:torsoextravest') and it['name'].startswith('Vest_')),
    ('ties', 'pattern', lambda it: it['dc'] == 'Accessory' and it['name'].startswith('Tie_')),
    ('holsters', 'pattern', lambda it: it['name'].startswith('Holster') and not MAKESHIFT.search(it['name'])),
    # The backpacks (one to two kilos); the home-made framepacks (four) are left to their own groups.
    ('backpacks', 'pattern', lambda it: it['itype'] == 'base:container' and '배낭' in it.get('ko', '')
     and not re.search(r'(Hydration|Crafted)', it['name']) and not MAKESHIFT.search(it['name'])),
    # Jewellery and watches.
    ('rings', 'pattern', lambda it: it['dc'] == 'Accessory' and it['name'].startswith('Ring_')),
    ('necklaces', 'field', lambda it: _wear(it, 'base:necklace', 'base:necklace_long')
     and it['name'].startswith('Necklace')),
    ('earrings', 'pattern', lambda it: it['dc'] == 'Accessory' and it['name'].startswith('Earring')),
    ('bracelets', 'pattern', lambda it: it['dc'] == 'Accessory' and it['name'].startswith('Bracelet')),
    ('watches', 'field', lambda it: it['itype'] == 'base:alarmclockclothing'),
    ('gems', 'hand', _ids('Diamond', 'Emerald', 'Ruby', 'Sapphire')),
    # Protective pads.
    # The light pads only (knee, elbow, soft shin pads, a neck guard; half a kilo): the hard shin guards, goalie
    # pads and shoulder pads weigh four to ten times as much and stay their own groups.
    ('pads', 'pattern', lambda it: it['dc'] == 'ProtectiveGear' and re.match(
        r'(Kneepad|ElbowPad|Shinpad_[LR](_Blue|_White)?$|IceHockeyNeckGuard)', it['name'])),
    # Toys, sport and play.
    ('balls', 'hand', _ids('Baseball', 'Basketball', 'Football', 'GolfBall', 'PoolBall', 'SoccerBall', 'TennisBall')),
    ('rackets', 'hand', _ids('BadmintonRacket', 'TennisRacket')),
    # The dolls and plush toys of the hand's size; the five-kilo teddy bear and big Spiffo stay apart.
    ('plush', 'pattern', lambda it: 'base:ismemento' in it['tags'] and _plain_ko(it).endswith('인형')
     and it['weight'] < 2),
    ('toys', 'hand', _ids('ToyCar', 'ToyPlane', 'Bricktoys', 'Yoyo', 'Cube', 'Revolver_CapGun', 'ToyBadge')),
    ('cards', 'pattern', lambda it: it['name'].startswith('Card_') and 'base:ismemento' in it['tags']),
    ('guitars', 'pattern', lambda it: it['name'].startswith('Guitar') and it['itype'] == 'base:weapon'
     and not MAKESHIFT.search(it['name'])),
    ('medals', 'pattern', lambda it: it['name'].startswith('Medal_')),
    ('christmas', 'pattern', lambda it: it['name'].startswith('Christmas') and 'base:ismemento' in it['tags']),
    ('videotapes', 'pattern', lambda it: it['name'].startswith('VHS_')),
    ('bats', 'hand', _ids('BaseballBat', 'BaseballBat_Metal')),
    # Household and kitchen.
    ('pillows', 'field', lambda it: 'base:pillow' in it['tags'] and not MAKESHIFT.search(it['name'])),
    ('tissues', 'hand', _ids('Tissue', 'TissueBox', 'ToiletPaper')),
    ('kettles', 'pattern', lambda it: it['name'].startswith('Kettle') and it['dc'] == 'Cooking'),
    ('buckets', 'field', lambda it: 'base:bucket' in it['tags'] and not re.search(r'(Debug|Large)', it['name'])),
    ('firstaidkit', 'pattern', lambda it: it['name'].startswith('FirstAidKit')),
    ('makeup', 'pattern', lambda it: it['dc'] == 'Appearance' and (it['name'].startswith('Makeup')
                                                                   or it['name'] == 'Lipstick')),
    ('pots', 'pattern', lambda it: _plain_ko(it) in ('요리용 냄비', '손잡이 냄비', '구리 손잡이 냄비')),
    ('canopener', 'field', lambda it: 'base:canopener' in it['tags'] and it['dc'] in ('Cooking', 'CookingWeapon')),
    ('bottleopener', 'field', lambda it: 'base:bottleopener' in it['tags'] and it['dc'] == 'Cooking'),
    ('cuttingboard', 'pattern', lambda it: it['name'].startswith('CuttingBoard')),
    ('glassware', 'field', lambda it: it['dc'] == 'WaterContainer' and 'base:glass' in it['tags']
     and it['name'].startswith(('Glass', 'DrinkingGlass'))),
    ('markers', 'pattern', lambda it: it['name'].startswith('Marker') and 'base:write' in it['tags']),
    ('pills', 'pattern', lambda it: it['dc'] == 'FirstAid' and it['name'].startswith('Pills')),
    ('cameras', 'field', lambda it: 'base:camera' in it['tags']),
    ('flashlights', 'field', lambda it: 'base:flashlight' in it['tags'] and it['dc'] == 'LightSource'
     and 'Crafted' not in it['name']),
    # Garden, fishing, trapping.
    ('sleepingbags', 'pattern', lambda it: it['name'].startswith('SleepingBag') and it['name'].endswith('_Packed')
     and not MAKESHIFT.search(it['name'])),
    ('lanterns', 'pattern', lambda it: it['dc'] == 'LightSource' and it['name'].startswith('Lantern')
     and 'Crafted' not in it['name']),
    ('shovels', 'field', lambda it: 'base:diggrave' in it['tags'] and not MAKESHIFT.search(it['name'])),
    ('seeds', 'pattern', lambda it: it['itype'] == 'base:literature' and 'BagSeed' in it['name']
     and not it['name'].endswith('_Empty')),
    # The traps set for animals; the mouse trap (a tenth of their weight, in every kitchen) stays apart.
    ('traps', 'pattern', lambda it: it['dc'] == 'Trapping' and it['name'].startswith('Trap')
     and it['name'] != 'TrapMouse'),
    ('lures', 'hand', _ids('JigLure', 'MinnowLure')),
    ('fishingline', 'pattern', lambda it: it['dc'] == 'Fishing' and it['name'].endswith('FishingLine')),
    ('wallpaper', 'field', lambda it: 'base:wallpaper' in it['tags']),
    # Guns and their parts.
    ('handguns', 'pattern', lambda it: 'base:firearm' in it['tags'] and it['dc'] == 'Weapon'
     and re.match(r'(Pistol|Revolver)', it['name'])),
    ('rifles', 'pattern', lambda it: 'base:firearm' in it['tags'] and it['dc'] == 'Weapon'
     and re.search(r'(Rifle|Carbine)', it['name'])),
    ('shotguns', 'pattern', lambda it: 'base:firearm' in it['tags'] and 'Shotgun' in it['name']),
    ('scopes', 'field', lambda it: 'base:optics' in it['tags'] and it['dc'] == 'WeaponPart'),
    ('chokes', 'pattern', lambda it: it['name'].startswith('ChokeTube')),
    # Car parts: the old, the regular and the performance kind are one part (as the tyres and brakes are by their tag).
    ('mufflers', 'pattern', lambda it: it['dc'] == 'VehicleMaintenance' and 'CarMuffler' in it['name']),
    ('suspension', 'pattern', lambda it: it['dc'] == 'VehicleMaintenance' and 'Suspension' in it['name']),
]
FAMILY_NAMES = {fid: 'IGUI_OA_ReqGroup_' + fid for fid, _, _ in FAMILIES}
# A family's picture (the member whose icon stands for it), where the most found member is not the plainest one.
FAMILY_ICONS = {'skillbook': 'Base.BookCarpentry1', 'recipemag': 'Base.CookingMag1', 'books': 'Base.Book',
                'reading': 'Base.Magazine', 'cans': 'Base.TinnedBeans', 'cannedbox': 'Base.TinnedBeans_Box',
                'frozen': 'Base.Frozen_FrenchFries', 'soda': 'Base.Pop2', 'candy': 'Base.Lollipop',
                'snacks': 'Base.Crisps', 'sauce': 'Base.Ketchup', 'vegetables': 'Base.Carrots', 'meat': 'Base.Steak',
                'hats': 'Base.Hat_BaseballCap', 'tobacco': 'Base.CigarettePack', 'balls': 'Base.SoccerBall', 'toys': 'Base.ToyCar',
                'jackets': 'Base.Jacket_WhiteTINT', 'shirts': 'Base.Shirt_FormalWhite'}

# A tag groups only when it is narrow: at most this many taken kinds, all of one display category.
TAG_MAX = 12
# Tags that name a property, not a thing (a recipe may still ask for them): never a group.
BROAD_TAGS = {
    'base:isfirefuel', 'base:hasmetal', 'base:ignorezombiedensity', 'base:morewhennozombies', 'base:ismemento',
    'base:fitskeyring', 'base:smeltableironsmall', 'base:smeltableironmedium', 'base:smeltableironlarge',
    'base:smeltablesteelsmall', 'base:smeltablesteelmedium', 'base:smeltablesteellarge',
    'base:makewoodcharcoalsmall', 'base:makewoodcharcoalmedium', 'base:makewoodcharcoallarge',
}

# Groups made by hand for what the rules above leave apart: id -> (name key, members). Few on purpose: the same
# appliance under different brands (the names differ by the brand, so neither the tags nor the names join them).
MANUAL = {
    'tv': ('IGUI_OA_ReqGroup_tv', ['Base.TvBlack', 'Base.TvWideScreen', 'Base.TvAntique']),
    'radio': ('IGUI_OA_ReqGroup_radio', ['Base.RadioBlack', 'Base.RadioRed', 'Base.RadioMakeShift', 'Base.Radio']),
    'walkietalkie': ('IGUI_OA_ReqGroup_walkietalkie', ['Base.WalkieTalkie1', 'Base.WalkieTalkie2',
                     'Base.WalkieTalkie3', 'Base.WalkieTalkie4', 'Base.WalkieTalkie5', 'Base.WalkieTalkieMakeShift']),
    'hamradio': ('IGUI_OA_ReqGroup_hamradio', ['Base.HamRadio1', 'Base.HamRadio2', 'Base.HamRadioMakeShift']),
}
# The groups that show a text of their own: the families and the groups by hand.
NAMED = dict(FAMILY_NAMES, **{gid: key for gid, (key, _) in MANUAL.items()})

# Left out, by rule, in this order. Each rule: (name, test(item) -> bool). The report lists every kind by rule.
def _id(it):
    return it['name']


EXCLUDE = [
    # Keys and key rings: a key opens one door of one house (padlocks are hardware and stay).
    ('key', lambda it: (it['itype'] == 'base:key' and 'base:lock' not in it['tags'])
     or re.match(r'^(Key\d|CarKey|KeyRing)', _id(it))),
    # Maps: one of each place.
    ('map', lambda it: it['itype'] == 'base:map' or it['dc'] == 'Cartography'),
    # Specimen jars: a few in labs and schools.
    ('specimen', lambda it: _id(it).startswith('Specimen')),
    # A container that does not look like one: a hollow book (a book outside, a stash inside).
    ('container posing as an item', lambda it: it['itype'] == 'base:container' and (
        it['dc'] == 'Literature' or 'base:hollowbook' in it['tags'])),
    # Someone's own papers and pictures: IDs, dog tags, tickets, diaries, photos, doodles, fliers.
    ('personal', lambda it: {'base:applyownername', 'base:picture'} & it['tags'] or _id(it).endswith('Pic')),
    # Newspapers, and paper the game itself calls uninteresting: mail, receipts, paperwork.
    ('newspaper or uninteresting paper', lambda it: {'base:uninteresting', 'base:newspaper'} & it['tags']),
    # A carton of boxes (nails, screws, cigarettes): a store's stock, not a thing a house has.
    ('bulk carton', lambda it: _id(it).endswith('Carton') and it['dc'] != 'Food'),
    # Trash: the junk the bins hand out, empties, wrappers and broken bits.
    ('trash', lambda it: it['trash']),
    # A drink's empty can or bottle (the beer can someone drank): the drink is the thing, the empty is rubbish.
    # The developers' test kinds (BucketWaterDebug, TestMug): no house has them on purpose.
    ('debug', lambda it: re.search(r'(Debug|^Test[A-Z])', _id(it))),
    ('empty drink', lambda it: it['dc'] == 'WaterContainer' and re.match(r'Beer(Can)?Empty$', _id(it))),
]

ROOMS_HOUSE = None   # read from Requests.lua (Requests.HOUSE_ROOMS)


# --- Lua literals --------------------------------------------------------------------------------------------------

TOKEN = re.compile(r'''
    (?P<ws>\s+) | (?P<comment>--\[\[.*?\]\]|--[^\n]*) |
    (?P<call>\((?:[^()]|\([^()]*\))*\)) |
    (?P<str>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*') |
    (?P<num>-?\d+\.?\d*(?:[eE][-+]?\d+)?|-?\.\d+) |
    (?P<name>[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*) |
    (?P<op>[{}\[\]=,;])
''', re.X | re.S)


class Ref:
    """A name in a table (ClutterTables.BinJunk): resolved against what the files assigned."""
    def __init__(self, name):
        self.name = name


def tokens(text, at):
    pos = at
    n = len(text)
    while pos < n:
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError('cannot read Lua at %d: %r' % (pos, text[pos:pos + 40]))
        pos = m.end()
        kind = m.lastgroup
        if kind in ('ws', 'comment', 'call'):     # a call's arguments: the name before stands for it
            continue
        yield kind, m.group(kind), pos


def parse_table(text, at):
    """The table literal starting at text[at] == '{': (value, end)."""
    it = tokens(text, at)
    stack = []

    def value(tok):
        kind, v, _ = tok
        if kind == 'str':
            return bytes(v[1:-1], 'utf-8').decode('unicode_escape') if '\\' in v else v[1:-1]
        if kind == 'num':
            return float(v)
        if kind == 'name':
            if v == 'true':
                return True
            if v == 'false':
                return False
            if v == 'nil':
                return None
            return Ref(v)
        if v == '{':
            return table()
        raise ValueError('unexpected %r' % v)

    def table():
        arr, dic = [], {}
        while True:
            tok = next(it)
            kind, v, _ = tok
            if v == '}':
                return {'arr': arr, 'dic': dic}
            if v in (',', ';'):
                continue
            if v == '[':
                key = value(next(it))
                assert next(it)[1] == ']'
                assert next(it)[1] == '='
                dic[key] = value(next(it))
                continue
            if kind == 'name' and '.' not in v:
                nxt = next(it)
                if nxt[1] == '=':
                    dic[v] = value(next(it))
                    continue
                arr.append(value(tok))
                if nxt[1] == '}':
                    return {'arr': arr, 'dic': dic}
                continue
            arr.append(value(tok))

    first = next(it)
    assert first[1] == '{'
    result = table()
    return result


def lua_assignments(path, names):
    """The tables the file assigns to the given names (a regex of the left side): { left side: table }."""
    text = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'^\s*(?:local\s+)?(%s)\s*=\s*\{' % names, text, re.M):
        out[m.group(1)] = parse_table(text, m.end() - 1)
    return out


def resolve(v, env, depth=0):
    if isinstance(v, Ref):
        return env.get(v.name)
    return v


# --- the game's data -----------------------------------------------------------------------------------------------

def read_items():
    items = {}
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        module = None
        for m in re.finditer(r'^\s*module\s+(\w+)|^\s*item\s+([\w.]+)\s*\{(.*?)\n\s*\}', text, re.M | re.S):
            if m.group(1):
                module = m.group(1)
                continue
            if not module:
                continue
            name, body = m.group(2), m.group(3)
            fields = {}
            for line in body.split('\n'):
                line = line.strip().rstrip(',')
                if '=' in line and not line.startswith('//'):
                    k, _, v = line.partition('=')
                    fields[k.strip().lower()] = v.strip()
            full = module + '.' + name
            tags = {t.strip().lower() for t in fields.get('tags', '').split(';') if t.strip()}
            items[full] = {
                'full': full, 'module': module, 'name': name, 'dc': fields.get('displaycategory', ''),
                'itype': fields.get('itemtype', '').lower(), 'weight': float(re.match(r'[-\d.]*', fields.get('weight', '1')).group(0) or 1),
                'tags': tags, 'icon': fields.get('icon'), 'trash': False, 'oneoff': False,
                'obsolete': fields.get('obsolete', '').lower() == 'true',
                'f': fields, 'body': fields.get('bodylocation', '').lower(), 'food': fields.get('foodtype', ''),
            }
    return items


def read_names(lang):
    path = os.path.join(MEDIA, 'lua', 'shared', 'Translate', lang, 'ItemName.json')
    return json.load(open(path, encoding='utf-8'))


def room_counts():
    """How many rooms of each name the maps have (as building-utilities' room_names.py reads the headers)."""
    result = Counter()
    for path in glob.glob(os.path.join(MEDIA, 'maps', '*', '*.lotheader')):
        data = open(path, 'rb').read()
        at = 0

        def integer():
            nonlocal at
            value = struct.unpack_from('<i', data, at)[0]
            at += 4
            return value

        def line():
            nonlocal at
            end = data.index(b'\n', at)
            value = data[at:end].decode('latin1').rstrip('\r')
            at = end + 1
            return value

        if data[:4] == b'LOTH':
            at = 4
        version = integer()
        for _ in range(integer()):
            line()
        if version == 0:
            at += 1
        integer(), integer()
        if version == 0:
            integer()
        else:
            integer(), integer()
        for _ in range(integer()):
            name = line()
            integer()
            rects = integer()
            at += 16 * rects
            objects = integer()
            at += 12 * objects
            result[name] += 1
    return result


def read_loot():
    """distribution table, procedural lists, the side tables (ClutterTables.*, BagsAndContainers.*)."""
    folder = os.path.join(MEDIA, 'lua', 'server', 'Items')
    env = {}
    for path in glob.glob(os.path.join(folder, 'Distribution_*.lua')):
        env.update(lua_assignments(path, r'(?:ClutterTables|BagsAndContainers)\.\w+'))
    dist = lua_assignments(os.path.join(folder, 'Distributions.lua'), 'distributionTable')['distributionTable']
    proc = lua_assignments(os.path.join(folder, 'ProceduralDistributions.lua'), r'ProceduralDistributions\.list')
    proc = proc['ProceduralDistributions.list']
    return dist, proc, env


def list_items(lst, env):
    """[(name, weight)] of a loot list table ({ rolls, items, junk }), its junk apart: (rolls, items, junk table)."""
    lst = resolve(lst, env)
    if not isinstance(lst, dict):
        return 0, [], None
    d = lst['dic']
    rolls = d.get('rolls', 1) or 1
    items = resolve(d.get('items'), env)
    pairs = []
    if isinstance(items, dict):
        arr = items['arr']
        for i in range(0, len(arr) - 1, 2):
            if isinstance(arr[i], str) and isinstance(arr[i + 1], float):
                pairs.append((arr[i], arr[i + 1]))
    return rolls, pairs, resolve(d.get('junk'), env)


def expected(lst, env, into, mult):
    """Adds the expected count of each item one fill of the list gives (rolls x chance, a chance capped at 1)."""
    rolls, pairs, junk = list_items(lst, env)
    for name, w in pairs:
        into[name] += mult * rolls * min(1.0, w / 100.0)
    if junk is not None:
        expected(junk, env, into, mult)


def sum_weights(lst, env, into, mult):
    """Adds the plain sum of the weights, junk included (with mult 0: names the items a list can hand out)."""
    rolls, pairs, junk = list_items(lst, env)
    for name, w in pairs:
        into[name] += w * mult
    if junk is not None:
        sum_weights(junk, env, into, mult)


def proc_shares(container):
    """How likely a procedural container takes each of its lists: weightChance (1 when not set) over the sum. A list
    the game forces for some tiles, rooms, zones or items gets the container's average share (no map data says
    where those are)."""
    plist = container['dic'].get('procList')
    if not isinstance(plist, dict):
        return []
    entries = [e['dic'] for e in plist['arr'] if isinstance(e, dict)]
    plain = [e for e in entries if not any(k in e for k in ('forceForTiles', 'forceForRooms', 'forceForZones', 'forceForItems'))]
    weights = [max(1.0, e.get('weightChance', 0) or 0) for e in plain]
    total = sum(weights) or 1.0
    out = [(e.get('name'), w / total) for e, w in zip(plain, weights)]
    forced = [e for e in entries if e not in plain]
    if forced:
        avg = 1.0 / max(1, len(entries))
        out += [(e.get('name'), avg) for e in forced]
    return out


SPECIAL_ROOM = re.compile(r'^(all|Bag_|Outfit_|AmmoStrap_)')
# Containers a room's list names that most such rooms do not have: the share of rooms that do. A plank stash is put
# under the floor of one building in a hundred (RBBasic.randomizeBuilding: Rand.NextBool(100)).
CONTAINER_SHARE = {'plankstash': 0.01}


def loot_scores(dist, proc, env, rooms):
    """Expected count of each item name over the whole map: per room name (times how many the maps have), per
    container (counted once a room), per list (its share). Then what bags and item containers found that way hold."""
    found = Counter()
    total_rooms = sum(rooms.values())
    containers_seen = Counter()
    for room, conts in dist['dic'].items():
        if not isinstance(conts, dict) or SPECIAL_ROOM.match(room):
            continue
        n = rooms.get(room, 0)
        if n == 0:
            continue
        for cname, cont in conts['dic'].items():
            cont = resolve(cont, env)
            if not isinstance(cont, dict) or cname in ('isShop', 'dontSpawnAmmo'):
                continue
            share = CONTAINER_SHARE.get(cname, 1.0)
            containers_seen[cname] += n * share
            fill_container(cont, proc, env, found, n * share)
    # 'all': the containers of a room that has no list of its own for them. No map data says how many there are: a
    # twentieth of as many as the rooms with their own list for that container have (a kitchen counter is everywhere,
    # a military locker in a few rooms). The dead's pockets once per room; an outfit's pockets (Outfit_*) as one
    # outfit of all of them.
    alld = dist['dic'].get('all')
    if isinstance(alld, dict):
        outfits = [c for c in alld['dic'] if c.startswith('Outfit_')]
        for cname, cont in alld['dic'].items():
            cont = resolve(cont, env)
            if not isinstance(cont, dict):
                continue
            if cname in ('inventorymale', 'inventoryfemale'):
                mult = total_rooms / 2.0
            elif cname.startswith('Outfit_'):
                mult = total_rooms / max(1, len(outfits))
            else:
                mult = containers_seen.get(cname, 0) / 20.0
            fill_container(cont, proc, env, found, mult)
    # What bags and boxes found so far hold: one level down.
    inner = Counter()
    for key, cont in dist['dic'].items():
        cont = resolve(cont, env)
        if not isinstance(cont, dict) or key in rooms or key == 'all' or key.startswith('Outfit_'):
            continue
        holder = found.get(key, 0)
        if holder <= 0:
            continue
        fill_container(cont, proc, env, inner, holder)
    found.update(inner)
    return found


def fill_container(cont, proc, env, into, mult):
    d = cont['dic']
    if d.get('procedural'):
        for name, share in proc_shares(cont):
            lst = proc['dic'].get(name)
            if lst is not None:
                expected(lst, env, into, mult * share)
    else:
        expected(cont, env, into, mult)


def house_names(dist, proc, env):
    """Every item name the house rooms' loot can hand out (the candidates' pool)."""
    out = Counter()
    for room in ROOMS_HOUSE:
        conts = dist['dic'].get(room)
        if not isinstance(conts, dict):
            continue
        for cont in conts['dic'].values():
            cont = resolve(cont, env)
            if isinstance(cont, dict):
                fill_container(cont, proc, env, out, 1)
                sum_weights(cont, env, out, 0)
    return out


# --- how easy a thing is to come by: the availability profile ------------------------------------------------------
#
# One number per kind: lam, how many of it an ordinary week of play turns up, by every way the game has. Each way is a
# Poisson rate, so the chance to come by at least one in a week is 1 - exp(-lam), and the ways (and the kinds of a
# group) add: 1 - prod(1 - p) = 1 - exp(-sum lam). The weekly amounts below set how the ways weigh against each other;
# only the order of the groups matters to the bands (Requests.lua ranks them), so they need to be sensible, not exact.
WEEK = {
    'rooms': 150,          # rooms looted in a week, of all the map's rooms (loot: the whole map's expected count x share)
    'cars': 10,            # cars whose glove box, seats and trunk are searched
    'strip': 1,            # cars taken apart for their parts
    'forage': 40,          # things found by foraging
    'plots': 8,            # plants of one crop a garden keeps (once the seed is had)
    'butcher': 1,          # animals butchered (each kind of animal as likely)
    'products': 2,         # eggs, wool, feathers from kept animals
    'fish': 6,             # fish caught (each species as likely)
    'net': 2,              # what a fishing net brings up (each kind as likely)
    'trap': 2,             # animals caught in traps (each as likely)
    'nature': 20,          # logs, branches, stones: as many as a week's work cuts and carries
}
SKILL_STEP = 0.8           # a recipe (or a foraging find) per level of skill it asks for: x0.8 (level 3 x0.51, 6 x0.26)
LEARN = 0.3                # a recipe that has to be learnt first (a magazine, a book)
TOOL_WEEKS = 4             # a tool is kept: the chance to have it is that of finding one in four weeks
CRAFT_CAP = 20             # a week's making of one thing, at most (time, not inputs, is the limit then)
VEHICLE_SPECIFIC = 0.09    # BaseVehicle: a vehicle's loot is one of its Specific lists when Rand.Next(100) <= 8
# The forage zones the map's objects.lua gives an area for (the forage definitions name a few more, from world
# generation, that no file sizes): a zone is as likely as its share of these areas.
FORAGE_ZONES = {'Forest': 'Forest', 'DeepForest': 'DeepForest', 'Vegitation': 'Vegitation', 'FarmLand': 'FarmLand',
                'TownZone': 'TownZone', 'TrailerPark': 'TrailerPark', 'Nav': 'ForagingNav'}
CHANNELS = ('loot', 'carloot', 'forage', 'farm', 'butcher', 'fish', 'trap', 'carpart', 'nature', 'craft')


def _full(t):
    t = re.sub(r'^\d+:', '', t.strip())
    return t if '.' in t else 'Base.' + t


def read_recipes(items):
    """craftRecipe blocks: { name, inputs: [ [(type, count)...] consumed ], tools: [ [(type, count)...] kept ], outputs:
    [(type, count)], skill (the highest level asked), learn, category (lower case), butchering (it gives Butchering
    xp) }. Tag inputs are the items with the tag; an alternative with its own count ("3:Base.LargeBranch") keeps it."""
    by_tag = defaultdict(list)
    for full, it in items.items():
        for t in it['tags']:
            by_tag[t].append(full)
    recipes = []
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        if 'craftRecipe' not in text:
            continue
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for m in re.finditer(r'craftRecipe\s+(\w+)\s*\{', text):
            depth, at = 1, m.end()
            while depth and at < len(text):
                c = text[at]
                depth += c == '{'
                depth -= c == '}'
                at += 1
            body = text[m.end():at - 1]
            rec = {'name': m.group(1), 'inputs': [], 'tools': [], 'outputs': [], 'skill': 0, 'learn': False,
                   'tags_used': set()}
            cat = re.search(r'^\s*category\s*=\s*(\w+)', body, re.M)
            rec['category'] = cat.group(1).lower() if cat else ''
            rec['butchering'] = bool(re.search(r'^\s*xpAward\s*=[^\n]*\bButchering\b', body, re.M))
            sk = re.search(r'SkillRequired\s*=\s*([^,\n]+)', body)
            if sk:
                levels = [int(x) for x in re.findall(r':(\d+)', sk.group(1))]
                rec['skill'] = max(levels) if levels else 0
            rec['learn'] = bool(re.search(r'NeedToBeLearn\s*=\s*true', body, re.I))
            part = re.search(r'\binputs\s*\{(.*?)\n\s*\}', body, re.S)
            outp = re.search(r'\boutputs\s*\{(.*?)\n\s*\}', body, re.S)
            for line in (part.group(1).split('\n') if part else []):
                line = line.strip()
                im = re.match(r'item\s+([\d.]+)\s', line)
                if not im:
                    continue
                count = float(im.group(1)) or 1.0
                alts = []
                lst = re.search(r'\[([^\]]*)\]', line)
                tg = re.search(r'tags\[([^\]]*)\]', line)
                if tg:
                    for t in tg.group(1).split(';'):
                        t = t.strip().lower()
                        rec['tags_used'].add(t)
                        alts += [(f, count) for f in by_tag.get(t, [])]
                elif lst:
                    for t in lst.group(1).split(';'):
                        t = t.strip()
                        if not t or t == '*':
                            continue
                        own = re.match(r'^(\d+):', t)
                        alts.append((_full(t), float(own.group(1)) if own else count))
                keep = 'mode:keep' in line or 'flags[Prop1' in line or 'flags[Prop2' in line or 'mode:use' in line
                (rec['tools'] if keep else rec['inputs']).append(alts)
            # An itemMapper names an output for each input ("Base.CarrotSeed = Base.CarrotBagSeed2"): an output
            # `mapper:NAME` is one of those, made from its own inputs.
            mappers = {}
            for name, mbody in _blocks(body, 'itemMapper'):
                rows = []
                for mm in re.finditer(r'([\w.]+)\s*=\s*([\w.;]+)', mbody):
                    if mm.group(1) != 'default':
                        rows.append((_full(mm.group(1)), [_full(t) for t in mm.group(2).split(';') if t]))
                mappers[name] = rows
            for line in (outp.group(1).split('\n') if outp else []):
                om = re.match(r'\s*item\s+([\d.]+)\s+(?:mapper:(\w+)|\[?([\w.]+))', line)
                if not om:
                    continue
                n = float(om.group(1)) or 1.0
                if om.group(2):
                    for out, ins in mappers.get(om.group(2), []):
                        rec['outputs'].append((out, n, set(ins)))
                else:
                    rec['outputs'].append((_full(om.group(3)), n, None))
            recipes.append(rec)
    return recipes


def cooking(r):
    """A recipe of the game's Cooking category: dishes, dough, slicing, opening packs and cans, coffee and toast. Food
    made that way is no way to come by food (the user, 2026-10-11); the raw food it is made from counts. Cutting up a
    catch (a small animal, a fish into fillets) is butchering though, which the game marks with Butchering xp, and
    it still counts."""
    return r.get('category') == 'cooking' and not r.get('butchering')


def craft_rates(recipes, have):
    """What a week's making gives of each output, from what the other ways give (`have`, a rate per kind; shallow: a
    recipe's inputs are not made in turn). A recipe makes as many times as its scarcest input allows (that input's
    rate over the count it takes, the alternatives of a slot added), times its outputs, times the chance to have each
    tool, x SKILL_STEP per level asked, x LEARN when it is learnt first; at most CRAFT_CAP. A recipe that takes back
    what it makes (a repair, a refill) gives nothing new, and cooking (`cooking`) is no way to come by food. Work
    stations are not counted. The best recipe counts:
    {type: (rate, recipe name)}."""
    out = {}

    def runs_of(r, only):
        """How many times a week the recipe can be made, the slots that hold any of `only` (a mapped output's own
        inputs) taking those alone."""
        runs = None
        for alts in r['inputs']:
            if not alts:
                continue
            if only and any(t in only for t, _ in alts):
                alts = [(t, c) for t, c in alts if t in only]
            n = sum(have.get(t, 0.0) / c for t, c in alts)
            runs = n if runs is None else min(runs, n)
        return runs or 0.0

    for r in recipes:
        if not r['outputs'] or not any(r['inputs']) or cooking(r):
            continue
        used = {t for alts in r['inputs'] + r['tools'] for t, _ in alts}
        factor = SKILL_STEP ** r['skill'] * (LEARN if r['learn'] else 1.0)
        for alts in r['tools']:
            if alts:
                factor *= 1 - math.exp(-TOOL_WEEKS * sum(have.get(t, 0.0) for t, _ in alts))
        for o, n, only in r['outputs']:
            if o in used:
                continue
            rate = min(CRAFT_CAP, runs_of(r, only) * factor * n)
            if rate > out.get(o, (0.0, ''))[0]:
                out[o] = (rate, r['name'], used, r)
    return out


def map_zones():
    """The area of each zone type the main map's objects.lua lays out, and of each name of its parking zones."""
    areas, parking = Counter(), Counter()
    for path in glob.glob(os.path.join(MEDIA, 'maps', '*', 'objects.lua')):
        for m in re.finditer(r'name = "([^"]*)", type = "(\w+)", x = -?\d+, y = -?\d+, z = -?\d+, width = (\d+), '
                             r'height = (\d+)', open(path, encoding='utf-8', errors='replace').read()):
            name, kind, area = m.group(1), m.group(2), int(m.group(3)) * int(m.group(4))
            areas[kind] += area
            if kind == 'ParkingStall':
                parking[name.lower()] += area
    return areas, parking


def _call_tables(text, fn):
    """The table literal given as the second argument of each call `fn(x, { ... })` in the text."""
    out = []
    for m in re.finditer(re.escape(fn) + r'\s*\(\s*[\w.]+\s*,\s*', text):
        if text[m.end()] == '{':
            out.append(parse_table(text, m.end()))
    return out


def _plain(v):
    """A parsed Lua table as Python: a dict when it has keys, else a list."""
    if isinstance(v, dict) and 'arr' in v and 'dic' in v:
        if v['dic']:
            return {k: _plain(x) for k, x in v['dic'].items()}
        return [_plain(x) for x in v['arr']]
    return v


def forage_rates(zone_area):
    """What a week's foraging finds of each kind. In a zone the game picks a category by its zone weight and then a
    kind of it by the kind's zone weight; a zone counts by its share of the map's zone area. A kind found in a few
    months only counts that share of the year; one that asks for a level of foraging x SKILL_STEP per level; the count
    found at once is the mean of minCount and maxCount. {type: rate}."""
    folder = os.path.join(MEDIA, 'lua', 'shared', 'Foraging')
    cats = _plain(lua_assignments(os.path.join(folder, 'forageCategories.lua'),
                                  r'forageSystem\.categoryDefinitions')['forageSystem.categoryDefinitions'])
    defs = []
    for path in sorted(glob.glob(os.path.join(folder, 'Categories', '*.lua'))):
        text = open(path, encoding='utf-8', errors='replace').read()
        tables = {}
        for m in re.finditer(r'^\s*local\s+(\w+)\s*=\s*\{', text, re.M):
            tables[m.group(1)] = _plain(parse_table(text, m.end() - 1))
        calls = [_plain(t) for t in _call_tables(text, 'forageSystem.addForageDef')]

        def value(v, spawn, full):
            if isinstance(v, Ref):
                if v.name.startswith('spawnTable.'):
                    return spawn.get(v.name.split('.', 1)[1]) if spawn else None
                if v.name in ('itemFullName',):
                    return full
                return None
            if isinstance(v, dict):
                return {k: value(x, spawn, full) for k, x in v.items()}
            if isinstance(v, list):
                return [value(x, spawn, full) for x in v]
            return v

        for table in tables.values():
            if not isinstance(table, dict):
                continue
            for key, row in table.items():
                if isinstance(row, dict) and isinstance(row.get('type'), str):
                    defs.append(row)                                    # a kind's own definition
                elif isinstance(row, dict) and isinstance(row.get('items'), dict):
                    for full in row['items'].values():                  # a spawn table: its kinds share the call
                        for call in calls:
                            d = value(call, row, full)
                            for k in ('skill', 'minCount', 'maxCount', 'months', 'categories', 'chance'):
                                if d.get(k) is None and row.get(k) is not None:
                                    d[k] = row[k]
                            defs.append(d)
                elif isinstance(row, str) and row.startswith('Base.'):
                    for call in calls:                                  # a flat list of kinds (junk food)
                        defs.append(value(call, None, row))
    total_area = sum(zone_area.get(k, 0) for k in FORAGE_ZONES) or 1
    zone_share = {FORAGE_ZONES[k]: zone_area.get(k, 0) / total_area for k in FORAGE_ZONES}
    weights = defaultdict(float)                # (category, zone) -> the sum of its kinds' weights
    for d in defs:
        for c in d.get('categories') or []:
            for z, w in (d.get('zones') or {}).items():
                if isinstance(w, (int, float)):
                    weights[(c, z)] += w
    cat_sum = defaultdict(float)
    for c, cd in cats.items():
        for z, w in (cd.get('zones') or {}).items():
            if isinstance(w, (int, float)) and weights.get((c, z)):
                cat_sum[z] += w
    rates = defaultdict(float)
    for d in defs:
        full = d.get('type')
        if not isinstance(full, str):
            continue
        months = d.get('months')
        season = len(months) / 12.0 if isinstance(months, list) and months else 1.0
        count = ((d.get('minCount') or 1) + (d.get('maxCount') or d.get('minCount') or 1)) / 2.0
        skill = d.get('skill') or 0
        p = 0.0
        for c in d.get('categories') or []:
            cw = (cats.get(c) or {}).get('zones') or {}
            for z, share in zone_share.items():
                w = (d.get('zones') or {}).get(z)
                if share and isinstance(w, (int, float)) and w > 0 and cat_sum.get(z) and weights.get((c, z)):
                    p += share * (cw.get(z, 0) or 0) / cat_sum[z] * w / weights[(c, z)]
        rates[full] += WEEK['forage'] * p * count * season * SKILL_STEP ** skill
    return rates


def farm_rows():
    """The crops: [(vegetable, [seed types], harvest count, hours to harvest)] (timeToGrow is the hours of each growth
    stage; the crop is harvested at harvestLevel, else at mature)."""
    rows = []
    for path in glob.glob(os.path.join(MEDIA, 'lua', 'server', 'Farming', 'farming_vegetableconf*.lua')):
        text = open(path, encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'^farming_vegetableconf\.props(?:\.(\w+)|\["(\w+)"\])\s*=\s*\{', text, re.M):
            d = _plain(parse_table(text, m.end() - 1))
            if not isinstance(d, dict) or not isinstance(d.get('vegetableName'), str):
                continue
            seeds = [s for s in (d.get('seedTypes') or []) if isinstance(s, str)]
            if isinstance(d.get('seedName'), str):
                seeds.append(d['seedName'])
            stages = d.get('harvestLevel') or d.get('mature') or 5
            veg = ((d.get('minVeg') or 1) + (d.get('maxVeg') or d.get('minVeg') or 1)) / 2.0
            rows.append((d['vegetableName'], seeds, veg, (d.get('timeToGrow') or 168) * stages))
    return rows


def farm_items():
    return {v for v, _, _, _ in farm_rows()} | {s for _, ss, _, _ in farm_rows() for s in ss}


def farm_rates(have):
    """A crop's harvest a week: WEEK plots x the harvest count x the harvests a week, x the chance to have its seed
    (`have`: the rate of each seed kind by the other ways and their making, as an opened seed packet)."""
    rates = defaultdict(float)
    for veg, seeds, count, hours in farm_rows():
        seed = 1 - math.exp(-sum(have.get(s, 0.0) for s in set(seeds) if s != veg))
        rates[veg] = max(rates[veg], WEEK['plots'] * count * 168.0 / hours * seed)
    return rates


def animal_rates():
    """Butchering, kept animals, fishing and trapping: {channel: {type: rate}}. Butchering: AnimalPartsDefinitions,
    each kind of animal as likely (its parts, bones, feathers, head and skull, by count). Products: the egg, wool and
    feather kinds of the animal definitions. Fishing: the species of fishing_properties (FishConfig) and what a net
    brings up. Trapping: what TrapDefinition's animals leave in a trap. Baits and lures are not catches."""
    lua = os.path.join(MEDIA, 'lua')
    parts = open(os.path.join(lua, 'shared', 'Definitions', 'animal', 'AnimalPartsDefinitions.lua'),
                 encoding='utf-8', errors='replace').read()
    per = defaultdict(lambda: defaultdict(float))
    for m in re.finditer(r'table\.insert\((\w+)\.(?:parts|bones),\s*\{item\s*=\s*"([\w.]+)",\s*(?:nb\s*=\s*([\d.]+)|'
                         r'minNb\s*=\s*([\d.]+),\s*maxNb\s*=\s*([\d.]+))', parts):
        n = float(m.group(3)) if m.group(3) else (float(m.group(4)) + float(m.group(5))) / 2
        per[m.group(1)][m.group(2)] += n
    for m in re.finditer(r'^(\w+)\.(?:feather|head|skull)\s*=\s*"([\w.]+)"', parts, re.M):
        per[m.group(1)][m.group(2)] += 1
    butcher = defaultdict(float)
    for animal in per.values():
        for t, n in animal.items():
            butcher[t] += WEEK['butcher'] * n / max(1, len(per))
    products = set()
    for path in glob.glob(os.path.join(lua, 'shared', 'Definitions', 'animal', '*Definitions.lua')):
        products |= set(re.findall(r'\.(?:eggType|woolType|featherItem)\s*=\s*"([\w.]+)"',
                                   open(path, encoding='utf-8', errors='replace').read()))
    for t in products:
        butcher[t] += WEEK['products']
    fishing = open(os.path.join(lua, 'shared', 'Fishing', 'fishing_properties.lua'), encoding='utf-8',
                   errors='replace').read()
    fish = defaultdict(float)
    species = set(re.findall(r'FishConfig:new\("([\w.]+)"\)', fishing))
    for t in species:
        fish[t] += WEEK['fish'] / len(species)
    net = set(re.findall(r'table\.insert\(Fishing\.fishNet(?:WithBait)?,\s*"([\w.]+)"\)', fishing))
    for t in net:
        fish[t] += WEEK['net'] / len(net)
    traps = set(re.findall(r'^\w+\.item\s*=\s*"([\w.]+)"', open(os.path.join(lua, 'server', 'Traps',
                           'TrapDefinition.lua'), encoding='utf-8', errors='replace').read(), re.M))
    trap = {t: WEEK['trap'] / len(traps) for t in traps}
    return {'butcher': butcher, 'fish': fish, 'trap': trap}


def _blocks(text, head):
    """(name, body) of each `head NAME { ... }` block at any depth."""
    for m in re.finditer(head + r'\s+(\w+)\s*\{', text):
        depth, at = 1, m.end()
        while depth and at < len(text):
            depth += text[at] == '{'
            depth -= text[at] == '}'
            at += 1
        yield m.group(1), text[m.end():at - 1]


def _top(body):
    """The lines of a block at its own depth (not inside its parts), and its parts: (lines, {part: body})."""
    lines, parts, depth, start, name = [], {}, 0, 0, None
    for i, line in enumerate(body.split('\n')):
        s = line.strip()
        if depth == 0:
            pm = re.match(r'part\s+([\w*]+)', s)
            if pm:
                name, start = pm.group(1), i
            elif s and s not in ('{', '}'):
                lines.append(s)
        depth += line.count('{') - line.count('}')
        if name and depth == 0 and '}' in line:
            parts[name] = '\n'.join(body.split('\n')[start + 1:i + 1])
            name = None
    return lines, parts


def vehicle_scripts(items):
    """Each vehicle script resolved through its templates: {vehicle: {item type: count}}. A part's itemType list is
    picked from at random (VehiclePart: Rand.Next over the list), and the kind is the item named with the vehicle's
    mechanicType after it (OldTire -> OldTire1) where the game has that item."""
    raw = {}
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        if 'vehicle' not in text:
            continue
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for kind, head in (('template', r'template\s+vehicle'), ('vehicle', r'(?<!template )\bvehicle')):
            for name, body in _blocks(text, head):
                lines, parts = _top(body)
                mech = next((int(x) for x in (re.match(r'mechanicType\s*=\s*(\d+)', s) for s in lines) if x for x in
                             [x.group(1)]), None)
                refs = [re.match(r'template!?\s*=\s*([\w/]+)', s).group(1) for s in lines
                        if re.match(r'template!?\s*=', s)]
                own = {}
                for pname, pbody in parts.items():
                    im = re.search(r'itemType\s*=\s*([\w.;]+)', pbody)
                    own[pname] = im.group(1).split(';') if im else None
                raw[(kind, name)] = (mech, refs, own)
    resolved = {}

    def parts_of(name, depth=0):
        """(mechanicType, {part: [item types] or None}) of a template or vehicle."""
        key = ('template', name) if ('template', name) in raw else ('vehicle', name)
        if key in resolved:
            return resolved[key]
        if key not in raw or depth > 8:
            return None, {}
        mech, refs, own = raw[key]
        out, m = {}, None
        for ref in refs:
            base, _, part = ref.partition('/part/')
            tm, tparts = parts_of(base, depth + 1)
            m = tm if tm is not None else m
            for p, types in tparts.items():
                if not part or p == part:
                    out[p] = types
        for p, types in own.items():
            if p.endswith('*'):
                for q in out:
                    if q.startswith(p[:-1]) and types is not None:
                        out[q] = types
            elif types is not None or p not in out:
                out[p] = types
        # A wildcard part of this block sets the parts it names, here or inherited.
        for p, types in own.items():
            if p.endswith('*') and types is not None:
                for q in [q for q in out if q.startswith(p[:-1])]:
                    out[q] = types
        out = {p: t for p, t in out.items() if not p.endswith('*')}
        result = (mech if mech is not None else m, out)
        resolved[key] = result
        return result

    vehicles = {}
    for kind, name in raw:
        if kind != 'vehicle':
            continue
        mech, parts = parts_of(name)
        counts = defaultdict(float)
        for types in parts.values():
            if not types:
                continue
            for t in types:
                t = _full(t)
                if mech is not None and t + str(mech) in items:
                    t = t + str(mech)
                counts[t] += 1.0 / len(types)
        vehicles['Base.' + name] = counts
    return vehicles


def vehicle_shares(parking):
    """How likely a car of the map is each vehicle script: VehicleZoneDistribution's spawnChance within a zone, the
    zones weighed by their parking area in objects.lua (an unnamed stall is a 'parkingstall'; 'rtrafficjam*' are the
    traffic jams). Burnt wrecks give nothing."""
    text = open(os.path.join(MEDIA, 'lua', 'shared', 'VehicleZoneDefinition.lua'), encoding='utf-8',
                errors='replace').read()
    zones = defaultdict(dict)
    for m in re.finditer(r'VehicleZoneDistribution\.(\w+)\.vehicles\["([\w.]+)"\]\s*=\s*\{[^}]*spawnChance\s*=\s*'
                         r'([\d.]+)', text):
        zones[m.group(1).lower()][m.group(2)] = float(m.group(3))
    weight = Counter()
    for name, area in parking.items():
        z = name or 'parkingstall'
        if z.startswith('rtrafficjam'):
            z = z[1:]
        if z in zones and 'burnt' not in z:
            weight[z] += area
    total = sum(weight.values()) or 1
    shares = defaultdict(float)
    for z, w in weight.items():
        s = sum(zones[z].values()) or 1
        for v, c in zones[z].items():
            shares[v] += w / total * c / s
    return shares


def vehicle_loot(env, items):
    """What one searched car holds of each kind on average: its VehicleDistributions entry (Normal, or one of its
    Specific lists at VEHICLE_SPECIFIC), every container of it filled once. {vehicle: {item name: count}}."""
    folder = os.path.join(MEDIA, 'lua', 'server', 'Vehicles')
    venv = dict(env)
    for path in glob.glob(os.path.join(folder, 'VehicleDistribution_*.lua')):
        venv.update(lua_assignments(path, r'ClutterTables\.\w+'))
    path = os.path.join(folder, 'VehicleDistributions.lua')
    venv.update(lua_assignments(path, r'VehicleDistributions\.\w+'))
    text = open(path, encoding='utf-8', errors='replace').read()
    table = parse_table(text, re.search(r'local distributionTable = \{', text).end() - 1)
    for k, v in list(venv.items()):
        if k.startswith('VehicleDistributions.') and isinstance(v, dict):
            for ck, cv in list(v['dic'].items()):
                v['dic'][ck] = resolve(cv, venv)
    out = {}

    def one(dist):
        found = Counter()
        dist = resolve(dist, venv)
        if isinstance(dist, dict):
            for cont in dist['dic'].values():
                cont = resolve(cont, venv)
                if isinstance(cont, dict):
                    expected(cont, venv, found, 1)
        return found

    for vname, entry in table['dic'].items():
        if not isinstance(entry, dict):
            continue
        normal = one(entry['dic'].get('Normal'))
        specific = [one(s) for s in (resolve(entry['dic'].get('Specific'), venv) or {'arr': []})['arr']]
        total = Counter({k: v * (1 - (VEHICLE_SPECIFIC if specific else 0)) for k, v in normal.items()})
        for s in specific:
            for k, v in s.items():
                total[k] += v * VEHICLE_SPECIFIC / len(specific)
        out['Base.' + vname] = total
    return out


def availability(items, loot, total_rooms, nature, recipes, env):
    """Every kind's weekly rate by each way: {type: {channel: rate}}, and what made the crafted ones ({type: recipe})."""
    zone_area, parking = map_zones()
    rate = defaultdict(lambda: defaultdict(float))
    for f, n in loot.items():
        rate[f]['loot'] += WEEK['rooms'] * n / max(1, total_rooms)
    shares = vehicle_shares(parking)
    carloot = vehicle_loot(env, items)
    for v, share in shares.items():
        for name, n in carloot.get(v, {}).items():
            rate[_full(name)]['carloot'] += WEEK['cars'] * share * n
    vparts = vehicle_scripts(items)
    for v, share in shares.items():
        for t, n in vparts.get(v, {}).items():
            rate[t]['carpart'] += WEEK['strip'] * share * n
    for t, r in forage_rates(zone_area).items():
        rate[t]['forage'] += r
    for ch, rates in animal_rates().items():
        for t, r in rates.items():
            rate[t][ch] += r
    for t in nature:
        rate[t]['nature'] += WEEK['nature']

    def total(skip=()):
        return {t: sum(v for c, v in ch.items() if c not in skip) for t, ch in rate.items()}

    # Shallow making: the seeds first (an opened seed packet), the crops from them, then everything from what the
    # other ways and the garden give.
    made = craft_rates(recipes, total())
    have = total()
    for t, (r, _, _, _) in made.items():
        have[t] = have.get(t, 0.0) + r
    for t, r in farm_rates(have).items():
        rate[t]['farm'] += r
    made = craft_rates(recipes, total())
    for t, (r, _, _, _) in made.items():
        rate[t]['craft'] += r
    return rate, {t: (name, used, rec) for t, (_, name, used, rec) in made.items()}


def group_rate(members, rate, made):
    """A group's weekly rate: the sum of its kinds', less what a kind is made from other kinds of the same group
    (cutting long socks short, a short-sleeved shirt from a long one: the group has the thing already). Such a kind's
    making is judged again with the group's own kinds taken out of its inputs (a fillet of any fish counts the fish
    the group does not hold)."""
    return sum(group_ways(members, rate, made).values())


def group_ways(members, rate, made):
    """A group's weekly rate by way ({channel: rate}), as group_rate counts it."""
    inside = set(members)
    total = Counter()
    for f in members:
        ch = rate.get(f, {})
        for c, v in ch.items():
            total[c] += v
        if ch.get('craft') and f in made and made[f][1] & inside:
            rec = made[f][2]
            have = {t: (0.0 if t in inside else sum(v for c, v in rate.get(t, {}).items() if c != 'craft'))
                    for t in made[f][1]}
            again = craft_rates([rec], have).get(f, (0.0,))[0] if rec else 0.0
            total['craft'] += again - ch['craft']
    return total


# --- the mod's rules -----------------------------------------------------------------------------------------------

def read_categories():
    text = open(CATEGORIES, encoding='utf-8').read()
    by_display = {}
    for m in re.finditer(r'fill\(D,\s*"(\w)",((?:\s*\.\.\s*|\s*)"[^"]*"(?:\s*\.\.\s*"[^"]*")*)\)', text):
        names = ''.join(re.findall(r'"([^"]*)"', m.group(2)))
        for n in names.split(','):
            by_display[n] = m.group(1)
    reject_display = dict(re.findall(r'(\w+)\s*=\s*"(\w+)"', re.search(r'REJECT_DISPLAY = \{(.*?)\n\}', text, re.S).group(1)))
    reject_id = dict(re.findall(r'(\w+)\s*=\s*"(\w+)"', re.search(r'REJECT_ID = \{(.*?)\n\}', text, re.S).group(1)))
    prefixes = re.findall(r'\{\s*"(\w+)",\s*"(\w+)"\s*\}', re.search(r'REJECT_PREFIX = \{(.*?)\n\}', text, re.S).group(1))
    units = dict((k, float(v)) for k, v in re.findall(r'(\w) = (\d+)', re.search(r'UNIT = \{(.*?)\}', text, re.S).group(1)))
    return by_display, reject_display, reject_id, prefixes, units


def read_cash():
    """Value.CASH: cash has its own value and is never a request."""
    text = open(VALUE, encoding='utf-8').read()
    return set(re.findall(r'\["([\w.]+)"\]', re.search(r'Value\.CASH = \{(.*?)\}', text).group(1)))


def read_house_rooms():
    text = open(REQUESTS, encoding='utf-8').read()
    body = re.search(r'HOUSE_ROOMS = \{(.*?)\}', text, re.S).group(1)
    return re.findall(r'"(\w+)"', body)


def make_category(by_display, reject_display, reject_id, prefixes):
    def category(it):
        """Categories.of for a script item (no cash, no own goods: vanilla only)."""
        if it['module'] == 'Base':
            if it['name'] in reject_id:
                return None
            for p, _ in prefixes:
                if it['name'].startswith(p):
                    return None
        if it['itype'] == 'base:moveable':
            return None
        dc = it['dc']
        if dc:
            if dc in reject_display:
                return None
            return by_display.get(dc, 'E')
        return 'E'
    return category


def read_band_rules():
    """Requests.lua's band rules, for the report (the mod ranks the saved candidates itself): the shares of the common
    and the normal band, and each band's price and quantities. {'share': {band: x}, 'bands': {band: {...}},
    'curve': x}."""
    text = open(REQUESTS, encoding='utf-8').read()
    share = dict((k, float(v)) for k, v in re.findall(r'(\w+) = ([\d.]+)',
                                                      re.search(r'BAND_SHARE = \{(.*?)\}', text).group(1)))
    bands = {}
    block = re.search(r'Requests\.BANDS = \{(.*?)\n\}', text, re.S).group(1)
    for name, body in re.findall(r'(common|normal|rare) = \{([^}]*)\}', block):
        bands[name] = dict((k, float(v)) for k, v in re.findall(r'(\w+) = ([\d.]+)', body))
    curve = float(re.search(r'QTY_CURVE = ([\d.]+)', text).group(1))
    return {'share': share, 'bands': bands, 'curve': curve}


BAND_ORDER = ('common', 'normal', 'rare')


def rank_bands(groups, rules):
    """The bands and quantities as Requests.lua gives them (Requests.ranks): the groups ranked by score, the most
    available first (ties by id), the first BAND_SHARE.common of them common, the next BAND_SHARE.normal normal, the
    rest rare; within a band the quantity runs from qtyMin (the least available) to qtyMax (the most) along the rank,
    to the power QTY_CURVE. Groups of an equal score take the first one's band and quantity."""
    order = sorted(groups.values(), key=lambda g: (-g['score'], g['id']))
    n = len(order)
    cut_common = int(n * rules['share']['common'] + 0.5)
    cut_normal = int(n * (rules['share']['common'] + rules['share']['normal']) + 0.5)
    spans = (('common', 0, cut_common), ('normal', cut_common, cut_normal), ('rare', cut_normal, n))
    lead = None
    for b, lo, hi in spans:
        d = rules['bands'][b]
        for i in range(lo, hi):
            g = order[i]
            g['rank'] = i + 1
            if lead is not None and g['score'] == lead['score']:      # an equal score: the first one's band
                g['band'], g['qty'] = lead['band'], lead['qty']
                continue
            t = 1.0 if hi - lo <= 1 else (hi - 1 - i) / (hi - 1 - lo)
            g['band'] = b
            g['qty'] = int(d['qtyMin'] + (d['qtyMax'] - d['qtyMin']) * t ** rules['curve'] + 0.5)
            lead = g


def old_band(score):
    """The band of a score as the table before the availability profile had it (1 and more common, 0.3 to 1 normal)."""
    return 'common' if score >= 1 else ('normal' if score >= 0.3 else 'rare')


def clean(name):
    """A name less its stray brackets (a ']' with no '[' before it, a '[' never closed: vanilla's Korean names have a
    few, "끈 없는 브라]") and with single spaces. Requests.clean does the same at run time."""
    out = []
    opens = []
    for c in name:
        if c == '[':
            opens.append(len(out))
            out.append(c)
        elif c == ']':
            if opens:
                opens.pop()
                out.append(c)
        else:
            out.append(c)
    for at in reversed(opens):
        del out[at]
    return ' '.join(''.join(out).split())


def strip_variant(name):
    """The words before the trailing ' [...]' of a name, stray brackets gone (Requests.plain)."""
    return re.sub(r'\s*\[[^\]]*\]\s*$', '', clean(name)).strip()


def inside(small, big):
    """Whether the words of `small` are in `big` in the same order (a name inside a longer one)."""
    at = 0
    for w in small:
        while at < len(big) and big[at] != w:
            at += 1
        if at == len(big):
            return False
        at += 1
    return True


def display_name(names):
    """The name the list shows for a group, as Requests.nameOf makes it at run time. `names`: one per member kind
    (the game-language names, a kind each). In this order: the shortest of the members' names (its words before
    ' [', stray brackets gone) that all the other names have inside them in order ("끈 없는 브라" for "끈 없는 프릴
    브라"); else the words all the members' names start with (less a trailing ' -' or an open bracket); else the
    words they all end with (less a leading ' -'); else the first member's name without its ' [...]'."""
    plain = [strip_variant(n) for n in names]
    if len(names) > 1:
        split = [p.split(' ') for p in plain]
        fits = [i for i, w in enumerate(split) if w != [''] and all(inside(w, o) for o in split)]
        if fits:
            return plain[min(fits, key=lambda i: (len(split[i]), len(plain[i]), i))]
    words = [clean(n).split(' ') for n in names]
    common = []
    for col in zip(*words):
        if len(set(col)) != 1:
            break
        common.append(col[0])
    while common and re.match(r'^[-:(\[]|.*[\[(]', common[-1]):
        common.pop()
    if len(names) > 1 and common:
        return ' '.join(common)
    if len(names) > 1:
        tail = []
        for col in zip(*[p.split(' ')[::-1] for p in plain]):
            if len(set(col)) != 1:
                break
            tail.append(col[0])
        while tail and re.match(r'^[-:)\]]|.*[)\]]', tail[-1]):
            tail.pop()
        if tail:
            return ' '.join(tail[::-1])
    return plain[0]


def near(a, b):
    """Whether two Korean names are of one thing: the words of one are inside the other, in order, or they are the
    same less their spaces ("공구상자", "공구 상자"). An English name two kinds share joins them only when their Korean
    names are near (vanilla's English names have typos too: "Rice" for a mashed sugar beet)."""
    a, b = strip_variant(a), strip_variant(b)
    wa, wb = a.split(' '), b.split(' ')
    if inside(wa, wb) or inside(wb, wa):
        return True
    return ''.join(a.split()) == ''.join(b.split())


def read_previous():
    """The table as the last run wrote it (it is the repository's): [(id, [was ids], [item types])]. A save keeps a
    group's id, so a group that moves must keep the id of the group most of its kinds came from, and an id that goes
    away is remembered in the row that took over (`was`)."""
    try:
        text = open(OUT, encoding='utf-8').read()
    except OSError:
        return []
    rows = []
    for line in text.split(chr(10)):
        ident = re.match(r'\s*\{ id = "([^"]*)",', line)
        body = re.search(r' items = \{ (.*) \} \},?$', line)
        if ident and body:
            was = re.search(r' was = \{ (.*?) \}', line)
            rows.append((ident.group(1), re.findall(r'"([^"]+)"', was.group(1)) if was else [],
                         re.findall(r'"([^"]+)"', body.group(1))))
    return rows


def keep_ids(groups, previous, items):
    """Names the groups of names (the 'n:' ones) after the previous table where they continue it, and gives every
    group the old ids it replaces (`was`: ids a save may still hold, that no group has now)."""
    old_of = {}
    for oid, _, ms in previous:
        for t in ms:
            old_of[t] = oid
    old_ids = {oid for oid, _, _ in previous}
    old_size = {oid: len(ms) for oid, _, ms in previous}
    named = [g for g in groups.values() if g['how'] == 'name']
    claims = []
    for g in named:
        count = Counter(old_of[t] for t in g['items'] if old_of.get(t, '').startswith('n:'))
        for oid, n in count.items():
            claims.append((-n, oid != g['id'], -old_size[oid], oid, g['id']))
    taken, gave = {}, {}
    for _, _, _, oid, gid in sorted(claims):
        if oid not in taken and gid not in gave:
            taken[oid], gave[gid] = gid, oid
    final = {}
    for g in named:
        final[g['id']] = gave.get(g['id'])
    used = set(gave.values())
    for g in sorted(named, key=lambda g: g['id']):
        if final[g['id']]:
            continue
        gid = g['id']
        while gid in used or gid in old_ids or any(o.get('id') == gid for o in groups.values() if o is not g):
            gid += '_'
        final[g['id']] = gid
        used.add(gid)
    for g in named:
        g['id'] = final[g['id']]
    # `was`: every old id that no group has now goes to the group most of its kinds went to.
    where = {t: g for g in groups.values() for t in g['items']}
    ids = {g['id'] for g in groups.values()}
    for g in groups.values():
        g['was'] = set()
    for oid, was, ms in previous:
        count = Counter(id(where[t]) for t in ms if t in where)
        if not count:
            continue
        top = count.most_common(1)[0][0]
        target = next(g for g in groups.values() if id(g) == top)
        for old in [oid] + was:
            if old not in ids and old not in items:
                target['was'].add(old)


# --- the whole thing -----------------------------------------------------------------------------------------------

def main():
    global ROOMS_HOUSE
    report_dir = None
    if '--report' in sys.argv:
        report_dir = sys.argv[sys.argv.index('--report') + 1]
    ROOMS_HOUSE = read_house_rooms()
    items = read_items()
    names_en, names_ko = read_names('EN'), read_names('KO')
    by_display, reject_display, reject_id, prefixes, units = read_categories()
    category = make_category(by_display, reject_display, reject_id, prefixes)
    dist, proc, env = read_loot()
    rooms = room_counts()

    def full_of(name):
        return name if '.' in name else 'Base.' + name

    # Trash: the junk on the bins' and dumpsters' own lists, empties, wrappers and broken bits of junk.
    trash_names = set()
    alld = dist['dic'].get('all')
    for cname in ('bin', 'dumpster'):
        cont = alld['dic'].get(cname) if alld else None
        if isinstance(cont, dict):
            trash_names |= {n for n, _ in list_items(cont, env)[1]}   # the bin's own list, not its random junk
    for full, it in items.items():
        if it['name'] in trash_names and it['dc'] in ('Junk', ''):
            it['trash'] = True
        if re.search(r'(Empty$|_Broken$|^Broken|^Smashed|Wrapper|DryerLint)', it['name']) and it['dc'] in ('Junk', ''):
            it['trash'] = True

    # The candidates' pool: what the house rooms hand out and the boxes take.
    house = house_names(dist, proc, env)

    cash = read_cash()

    def taken(full):
        it = items.get(full)
        return it is not None and not it['obsolete'] and full not in cash and category(it) is not None

    # Loot over the whole map.
    loot = Counter()
    for n, v in loot_scores(dist, proc, env, rooms).items():
        loot[full_of(n)] += v

    # Left out, by rule.
    excluded = defaultdict(list)

    def exclusion(it):
        for rule, test in EXCLUDE:
            if test(it):
                return rule
        return None

    pool = sorted({full_of(n) for n in house if taken(full_of(n))})
    candidates = []
    for full in pool:
        rule = exclusion(items[full])
        if rule:
            excluded[rule].append(full)
        else:
            candidates.append(full)

    # Every taken, not left out item can be a member (a crafted twin of a looted thing: CharcoalCrafted).
    members_ok = {f for f, it in items.items() if taken(f) and not exclusion(it)}

    # --- groups ---
    group_of = {}
    groups = {}

    def add(gid, full, how):
        group_of[full] = gid
        g = groups.setdefault(gid, {'id': gid, 'how': how, 'items': []})
        g['items'].append(full)

    # 0. the families (one level above the kind).
    FARM.update(farm_items())
    cand_set = set(candidates)
    for full, it in items.items():
        it['ko'], it['en'], it['cand'] = names_ko.get(full, ''), names_en.get(full, ''), full in cand_set
    for full in sorted(members_ok):
        for fid, _, test in FAMILIES:
            if test(items[full]):
                add(fid, full, 'family')
                break
    # 1. narrow tags the recipes ask for.
    recipes = read_recipes(items)
    recipe_tags = set()
    for r in recipes:
        recipe_tags |= r['tags_used']
    tag_members = defaultdict(set)
    for full in members_ok:
        for t in items[full]['tags']:
            if t in recipe_tags and t not in BROAD_TAGS:
                tag_members[t].add(full)
    narrow = {}
    for t, ms in tag_members.items():
        dcs = {items[f]['dc'] for f in ms}
        if 2 <= len(ms) <= TAG_MAX and len(dcs) == 1 and any(f in candidates for f in ms):
            narrow[t] = ms
    for full in sorted(members_ok):
        if full in group_of:
            continue
        best = None
        for t in items[full]['tags']:
            if t in narrow:
                left = [f for f in narrow[t] if f not in group_of or group_of[f] == t]
                if len(left) >= 2 and (best is None or (len(narrow[t]), t) < (len(narrow[best]), best)):
                    best = t
        if best:
            for f in sorted(narrow[best]):
                if f not in group_of:
                    add(best, f, 'tag')
    # 2. variants: the same name before ' [' in Korean or in English (stray brackets gone), of one display category.
    #    Vanilla's Korean names have typos ("끈 없는 브라]") and say the same thing in different words ("끈 없는 프릴
    #    브라" for the English "Bra - Strapless"), so either language joins two kinds (union-find over both).
    loose = [f for f in sorted(members_ok) if f not in group_of and (names_ko.get(f) or names_en.get(f))]
    parent = {f: f for f in loose}

    def find(f):
        while parent[f] != f:
            parent[f] = parent[parent[f]]
            f = parent[f]
        return f

    seen_key = defaultdict(list)
    for f in loose:
        keys = []
        ko_prefix = ''.join(strip_variant(names_ko.get(f, '')).casefold().split())      # "공구상자" and "공구 상자"
        if ko_prefix:
            keys.append(('ko', ko_prefix))
        en_prefix = strip_variant(names_en.get(f, '')).casefold()
        if en_prefix:
            keys.append(('en', items[f]['dc'], en_prefix))
        for k in keys:
            for other in seen_key[k]:
                # An English match joins two kinds only when their Korean names are near each other too.
                if k[0] == 'ko' or not (names_ko.get(f) and names_ko.get(other)) or near(names_ko[f], names_ko[other]):
                    parent[find(f)] = find(other)
            seen_key[k].append(f)
    clusters = defaultdict(list)
    for f in loose:
        clusters[find(f)].append(f)
    for ms in sorted(clusters.values(), key=lambda m: m[0]):
        if len(ms) >= 2 and any(f in candidates for f in ms):
            # The id: the English words the members' names start with (a save keeps it), else the first member's.
            words = [clean(names_en.get(f, '')).split() for f in ms]
            common = []
            for col in zip(*words):
                if len(set(col)) != 1:
                    break
                common.append(col[0])
            stem = re.sub(r'\W+', '_', ' '.join(common)).strip('_') or items[ms[0]]['name']
            gid = 'n:' + stem
            while gid in groups:
                gid = gid + '_'
            for f in ms:
                add(gid, f, 'name')
    # 3. by hand.
    for gid, (key, ms) in MANUAL.items():
        for f in ms:
            if f in members_ok and f not in group_of:
                add(gid, f, 'manual')
    # The rest: on their own.
    for full in candidates:
        if full not in group_of:
            add(full, full, 'single')

    # Only groups with a candidate member are on the list.
    cand_set = set(candidates)
    groups = {gid: g for gid, g in groups.items() if any(f in cand_set for f in g['items'])}
    # Groups the list would show under the same Korean name are one group (a week never shows a name twice).
    # A group that would show a family's or a hand group's own name joins it.
    rank = {'family': 0, 'tag': 1, 'manual': 2, 'name': 3, 'single': 4}
    ui_ko = json.load(open(UI_KO, encoding='utf-8'))
    shown = {ui_ko[NAMED[gid]]: gid for gid in groups if gid in NAMED}
    for gid in sorted(groups, key=lambda g: (rank[groups[g]['how']], -len(groups[g]['items']), g)):
        g = groups[gid]
        if gid in NAMED:
            continue
        label = display_name([names_ko.get(f) or names_en.get(f) or f for f in g['items']])
        if label in shown:
            into = groups[shown[label]]
            into['items'] += g['items']
            into['merged'] = into.get('merged', []) + [gid]
            del groups[gid]
        else:
            shown[label] = gid

    # --- how easy: every kind's weekly rate by every way, a group's the sum of its kinds' ---
    nature = {'Base.' + n for n, why in reject_id.items() if why == 'Nature'} | {'Base.Log', 'Base.LargeBranch',
              'Base.TreeBranch2', 'Base.Twigs', 'Base.Stone', 'Base.SharpedStone', 'Base.FlatStone', 'Base.Plank',
              'Base.Sapling', 'Base.Rock'}
    rate, made_by = availability(items, loot, sum(rooms.values()), nature, recipes, env)
    lam = {t: sum(ch.values()) for t, ch in rate.items()}
    for g in groups.values():
        g['lam'] = group_rate(g['items'], rate, made_by)
        g['score'] = float('%.4g' % g['lam'])
        g['items'].sort(key=lambda f: (-lam.get(f, 0.0), f))
        # The dearest member by weight, of the category most of the group's candidates are of (a family of hats
        # with a few keepsake hats among them stays clothing: the row's dc is its category in the saved table).
        cats = Counter(category(items[f]) for f in g['items'] if f in cand_set)
        main = cats.most_common(1)[0][0] if cats else None
        pool = [f for f in g['items'] if category(items[f]) == main] or g['items']
        heavy = max(pool, key=lambda f: items[f]['weight'] * units.get(category(items[f]) or 'E', 0))
        g['wt'] = items[heavy]['weight']
        g['dc'] = items[heavy]['dc']
        if g['id'] in FAMILY_ICONS and FAMILY_ICONS[g['id']] in g['items']:
            g['icon'] = FAMILY_ICONS[g['id']]
        else:
            g['icon'] = g['items'][0]
    rules = read_band_rules()
    rank_bands(groups, rules)

    previous = read_previous()
    keep_ids(groups, previous, items)
    write_lua(groups)
    if report_dir:
        write_report(report_dir, groups, excluded, items, names_ko, rate, made_by, previous, candidates, units,
                     category, rules)
        write_family_report(report_dir, groups, previous, items, names_ko, cand_set, units, category)
    print('groups: %d (%s), from %d kinds' % (len(groups), dict(Counter(g['band'] for g in groups.values())),
                                             len(candidates)))
    print('left out:', {k: len(v) for k, v in excluded.items()})
    return 0


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def write_lua(groups):
    rows = sorted(groups.values(), key=lambda g: g['id'])
    body = []
    for g in rows:
        parts = ['id = ' + lua_str(g['id']), 'score = %g' % g['score'], 'wt = %g' % g['wt'], 'dc = ' + lua_str(g['dc'])]
        if g['id'] in NAMED:
            parts.append('name = ' + lua_str(NAMED[g['id']]))
        if g['was']:
            parts.append('was = { %s }' % ', '.join(lua_str(w) for w in sorted(g['was'])))
        if g['icon'] != g['items'][0]:
            parts.append('icon = ' + lua_str(g['icon']))
        items = ', '.join(lua_str(f) for f in g['items'])
        body.append('    { %s, items = { %s } },' % (', '.join(parts), items))
    # The stamp tells the world save which table it was made from (Requests.data makes the saved one again when it differs).
    stamp = '%08x' % zlib.crc32('\n'.join(body).encode('utf-8'))
    out = [
        "-- The request groups (NUMBERS 2): made by tools/request_groups.py from the game's files. Do not edit by hand:",
        '-- change the tool and run it again. A row: { id, score, wt, dc, items = { fullType ... }, name, was, icon }. id is',
        "-- the group's key in a save (a member's fullType for a group of one), score how many of its members an",
        "-- ordinary week turns up by every way the game has (Requests.lua ranks the groups by it into the bands), wt and",
        "-- dc the weight and display category of its dearest member (the group's category), items the kinds it takes,",
        "-- the easiest to come by first;",
        '-- name (a translation key) only for the families named by hand, was the ids the group had before a save may',
        '-- still hold (a group that was joined to this one), icon only when it is not the first item.',
        'require "OperationAcorn/Core"',
        '',
        'OperationAcorn.RequestGroupsStamp = "%s"' % stamp,
        'OperationAcorn.RequestGroups = {',
    ] + body + ['}']
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')


def write_family_report(folder, groups, previous, items, names_ko, cand_set, units, category):
    """The families, each with its members (*: not a house candidate), and the earlier groups the families took apart."""
    ui_ko = json.load(open(UI_KO, encoding='utf-8'))
    ui_en = json.load(open(UI_KO.replace(os.sep + 'KO' + os.sep, os.sep + 'EN' + os.sep), encoding='utf-8'))
    source = {fid: how for fid, how, _ in FAMILIES}
    path = os.path.join(folder, 'request-families.txt')
    where = {t: g['id'] for g in groups.values() for t in g['items']}
    with open(path, 'w', encoding='utf-8') as f:
        for fid, _, _ in FAMILIES:
            g = groups.get(fid)
            if not g:
                f.write('%s: no candidate\n' % fid)
                continue
            key = FAMILY_NAMES[fid]
            f.write('%s\t%s\t%s\t%s\t%s %.4g (rank %d, qty %d)\t%d kinds, %d candidates\ticon %s\n' % (
                fid, ui_ko[key], ui_en[key], source[fid], g['band'], g['score'], g['rank'], g['qty'],
                len(g['items']), sum(1 for t in g['items'] if t in cand_set), g['icon']))
            if g.get('merged'):
                f.write('    joined by name: %s\n' % ', '.join(g['merged']))
            seen = []
            for t in g['items']:
                label = strip_variant(names_ko.get(t, t))
                mark = label + ('' if t in cand_set else '*')
                if label not in [x.rstrip('*') for x in seen]:
                    seen.append(mark)
            f.write('    ' + ', '.join(seen) + '\n')
        f.write('\nEARLIER GROUPS SPLIT (kind -> group now)\n')
        fams = set(FAMILY_NAMES)
        for oid, _, ms in previous:
            now = Counter(where.get(t, '-') for t in ms)
            if len(now) > 1 and any(k in fams for k in now) and any(k not in fams and k != '-' for k in now):
                f.write('%s: %s\n' % (oid, ', '.join('%s %s->%s' % (t, names_ko.get(t, ''), where.get(t, '-'))
                                                      for t in ms)))
    print('report:', path)


def read_old_scores(path):
    """{id: score} of a RequestGroups.lua (the comparison of --old)."""
    out = {}
    for m in re.finditer(r'\{ id = "([^"]*)", score = ([\d.e+-]+),', open(path, encoding='utf-8').read()):
        out[m.group(1)] = float(m.group(2))
    return out


def write_report(folder, groups, excluded, items, names_ko, rate, made_by, previous, candidates, units, category,
                 rules):
    """request-groups.txt (what was left out, every group with its members' ways) and request-groups.tsv (a row a
    group: rank, id, name, band, qty, score, chance a week, the ways by share, members, the cheapest and dearest
    member's worth, and the score and band of --old)."""
    os.makedirs(folder, exist_ok=True)
    old = read_old_scores(sys.argv[sys.argv.index('--old') + 1]) if '--old' in sys.argv else {}
    ui_ko = json.load(open(UI_KO, encoding='utf-8'))

    def label(g):
        if g['id'] in NAMED:
            return ui_ko[NAMED[g['id']]]
        return display_name([names_ko.get(f) or f for f in g['items']])

    def ways(fs):
        tot = group_ways(fs, rate, made_by)
        s = sum(tot.values()) or 1
        return ' '.join('%s %d%%' % (ch, round(100 * v / s)) for ch, v in tot.most_common() if v / s >= 0.005)

    def worth(f):
        return items[f]['weight'] * units.get(category(items[f]) or 'E', 0)

    path = os.path.join(folder, 'request-groups.txt')
    order = sorted(groups.values(), key=lambda g: (-g['score'], g['id']))
    with open(path, 'w', encoding='utf-8') as f:
        f.write('%d groups %s from %d kinds\n\n' % (len(groups), dict(Counter(g['band'] for g in groups.values())),
                                                    len(candidates)))
        for rule, ms in excluded.items():
            f.write('LEFT OUT (%s): %d\n' % (rule, len(ms)))
            for m in ms:
                f.write('    %s  %s\n' % (m, names_ko.get(m, '')))
        f.write('\nALL GROUPS BY SCORE (rank band qty score chance id name ways)\n')
        for g in order:
            f.write('%4d %-6s %2d %9.4g %5.1f%%  %-34s %s  [%s]\n' % (g['rank'], g['band'], g['qty'], g['score'],
                    100 * (1 - math.exp(-g['score'])), g['id'], label(g), ways(g['items'])))
            for m in g['items'][:12]:
                ch = rate.get(m, {})
                f.write('         %-36s %-24s %8.4g  %s%s\n' % (m, names_ko.get(m, '')[:24], sum(ch.values()),
                        ' '.join('%s=%.3g' % (c, v) for c, v in sorted(ch.items(), key=lambda x: -x[1]) if v > 0),
                        ('  <- ' + made_by[m][0]) if ch.get('craft') else ''))
            if len(g['items']) > 12:
                f.write('         ... %d more\n' % (len(g['items']) - 12))
    tsv = os.path.join(folder, 'request-groups.tsv')
    with open(tsv, 'w', encoding='utf-8') as f:
        f.write('rank\tid\tname\tband\tqty\tscore\tchance\tways\tmembers\tcheapest\tdearest\told_score\told_band\n')
        for g in order:
            prev = old.get(g['id'])
            if prev is None:
                for w in sorted(g.get('was', ())):
                    if w in old:
                        prev = old[w]
            f.write('\t'.join(str(x) for x in (
                g['rank'], g['id'], label(g), g['band'], g['qty'], '%.4g' % g['score'],
                '%.1f' % (100 * (1 - math.exp(-g['score']))), ways(g['items']), len(g['items']),
                '%d' % min(worth(m) for m in g['items']), '%d' % max(worth(m) for m in g['items']),
                '' if prev is None else '%.4g' % prev, '' if prev is None else old_band(prev))) + '\n')
    print('report:', path, tsv)


if __name__ == '__main__':
    sys.exit(main())
