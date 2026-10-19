"""Record the user's picks from the title lab into title_picks.json (SOUND-SYSTEM.md S7):

    python -X utf8 pick.py stamp:land=stamp_land_06_r2.ogg dust:leave=dust_leave_03.ogg ...

Each pick keeps how it was made (gen/prompts.json), with what a refinement leaves out (its prompt, seed, length, peak time)
taken from the pick it was refined from, so that it can itself be refined again. A cue not named keeps its pick.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PICKS = os.path.join(HERE, 'title_picks.json')
PROMPTS = os.path.join(HERE, 'gen', 'prompts.json')
KEEP = ('prompt', 'seed', 'made', 'kept', 'at')


def main(argv):
    picks = json.load(open(PICKS, encoding='utf-8')) if os.path.exists(PICKS) else {}
    made = json.load(open(PROMPTS, encoding='utf-8'))
    for arg in argv:
        cue, _, file = arg.partition('=')
        if file not in made:
            raise SystemExit('%s: not in gen/prompts.json' % file)
        how = made[file]
        old = picks.get(cue) or {}
        parent = made.get(how.get('from_pick'), {}) if how.get('from_pick') else {}
        pick = {'file': file}
        for k in KEEP:
            v = how.get(k, parent.get(k, old.get(k)))
            if v is not None:
                pick[k] = v
        if 'at' in how or 'at' not in pick:
            pick['at'] = how.get('at', parent.get('at', old.get('at', 0.0)))
        picks[cue] = pick
        print('%-16s %s' % (cue, file))
    with open(PICKS, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(picks, f, ensure_ascii=False, indent=1)
        f.write('\n')


if __name__ == '__main__':
    main(sys.argv[1:])
