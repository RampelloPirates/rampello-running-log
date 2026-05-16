#!/usr/bin/env python
"""
generate_demo_data.py -- emit a SQL script that seeds Rampello with realistic
fake athletes + runs so every feature can be exercised before launch.

Tagged for trivial cleanup: every seeded athlete uses an email under the
@piratesdemo.test domain, so a single DELETE FROM athletes WHERE email LIKE
'%@piratesdemo.test'; clears all of it (runs / run_segments / race_results
cascade away via FK ON DELETE CASCADE).

Usage:
    python tools/generate_demo_data.py > sql/seed_demo_data.sql

Then paste that .sql into the Supabase SQL Editor and run.
"""

import random
import uuid
from datetime import date, timedelta

random.seed(42)  # reproducible

TODAY = date.today()
WEEKS_BACK = 4
START_DATE = TODAY - timedelta(days=WEEKS_BACK * 7)

# -- Athlete roster ---------------------------------------------------------
# (first, last, grade, gender, profile)
# profile keys:
#   weekly_mi -- target running miles in the most recent full week
#   easy_pace -- typical easy pace seconds/mile
#   workout_pace -- typical tempo/intervals pace seconds/mile
#   cadence -- approximate spm (some kids without watches get None)
#   growth -- multiplier per week (1.05 = +5% growth, 1.0 = flat)
#   spike -- (week_index, multiplier) for one ramp event (None = none)
ATHLETES = [
    ('Sarah',   'Johnson',   7, 'F', dict(weekly_mi=18, easy_pace=600, workout_pace=510, cadence=176, growth=1.05, spike=None)),
    ('Michael', 'Brown',     8, 'M', dict(weekly_mi=22, easy_pace=540, workout_pace=470, cadence=182, growth=1.04, spike=None)),
    ('Emma',    'Davis',     6, 'F', dict(weekly_mi=14, easy_pace=620, workout_pace=540, cadence=174, growth=1.06, spike=None)),
    ('Lucas',   'Patel',     5, 'M', dict(weekly_mi=11, easy_pace=660, workout_pace=580, cadence=None, growth=1.08, spike=None)),
    ('Ava',     'Smith',     7, 'F', dict(weekly_mi=16, easy_pace=605, workout_pace=525, cadence=178, growth=1.06, spike=None)),
    ('Noah',    'Thompson',  8, 'M', dict(weekly_mi=14, easy_pace=585, workout_pace=505, cadence=180, growth=1.05, spike=(3, 1.30))),  # YELLOW flag this wk
    ('Mia',     'Garcia',    4, 'F', dict(weekly_mi=6,  easy_pace=720, workout_pace=640, cadence=None, growth=1.10, spike=None)),
    ('Liam',    'Wilson',    6, 'M', dict(weekly_mi=12, easy_pace=640, workout_pace=560, cadence=None, growth=1.04, spike=(3, 1.55))),  # RED flag this wk
    ('Olivia',  'Martinez',  5, 'F', dict(weekly_mi=9,  easy_pace=680, workout_pace=600, cadence=None, growth=1.07, spike=None)),
    ('Ethan',   'Rodriguez', 8, 'M', dict(weekly_mi=20, easy_pace=560, workout_pace=485, cadence=184, growth=1.02, spike=None)),
    ('Sophia',  'Anderson',  3, 'F', dict(weekly_mi=4,  easy_pace=750, workout_pace=680, cadence=None, growth=1.12, spike=None)),
    ('Mason',   'Taylor',    7, 'M', dict(weekly_mi=17, easy_pace=575, workout_pace=495, cadence=180, growth=1.05, spike=None)),
]

# Routes the team uses (so the route autocomplete looks lived-in)
ROUTES = [
    'Bayshore out & back',
    'Hyde Park loop',
    'Riverwalk + bridges',
    'Davis Islands loop',
    'Al Lopez Park trails',
    'Track at Plant HS',
    'Neighborhood — easy',
    'Curtis Hixon waterfront',
]

# Cross-training activities
XT_ACTIVITIES = ['swimming', 'biking', 'elliptical', 'stretch + core', 'pool run']


def sql_text(s):
    if s is None: return 'NULL'
    return "'" + str(s).replace("'", "''") + "'"


def sql_num(v):
    if v is None: return 'NULL'
    return str(v)


def emit_athletes(out):
    rows = []
    for first, last, grade, gender, _ in ATHLETES:
        aid = str(uuid.uuid4())
        email = f'{first.lower()}.{last.lower()}@piratesdemo.test'
        parent_email = f'parent.{last.lower()}@piratesdemo.test'
        rows.append((aid, first, last, email, grade, gender, parent_email))
        ATHLETE_IDS[f'{first} {last}'] = aid
    out.append('-- - Athletes -')
    out.append(
        'INSERT INTO athletes (id, first_name, last_name, email, grade, gender, '
        'joined_date, active, signup_source, parent_first_name, parent_last_name, '
        'parent_email, parent_phone) VALUES'
    )
    vals = []
    for aid, f, l, em, g, gen, pe in rows:
        vals.append(
            f"  ('{aid}', '{f}', '{l}', '{em}', {g}, '{gen}', "
            f"current_date - interval '60 days', true, 'manual', "
            f"'Parent', '{l}', '{pe}', '(813) 555-{random.randint(1000,9999)}')"
        )
    out.append(',\n'.join(vals) + ';')
    out.append('')


def run_distance_for(profile, run_type):
    """Pick a sensible distance (miles) for the given run type and profile."""
    base = profile['weekly_mi']
    if run_type == 'long':       return round(random.uniform(base * 0.30, base * 0.40), 2)
    if run_type == 'tempo':      return round(random.uniform(base * 0.20, base * 0.28), 2)
    if run_type == 'intervals':  return round(random.uniform(base * 0.18, base * 0.25), 2)
    if run_type == 'race':       return round(random.uniform(1.86, 3.1), 2)  # 3K-5K
    # easy
    return round(random.uniform(base * 0.12, base * 0.20), 2)


def duration_for(distance, run_type, profile):
    """Compute total duration_seconds based on type-specific pace."""
    if run_type in ('intervals', 'tempo', 'race'):
        pace = profile['workout_pace']
        # workouts include warmup/cooldown easy bookends, so blended pace is between
        blended = (pace + profile['easy_pace']) / 2 if run_type != 'race' else pace
    elif run_type == 'long':
        blended = profile['easy_pace'] + 30  # long runs slightly slower
    else:
        blended = profile['easy_pace']
    # +/- 5% jitter
    blended *= random.uniform(0.95, 1.05)
    return int(round(distance * blended))


def emit_run(out, athlete_name, profile, run_date, run_type, race_meet=None):
    aid = ATHLETE_IDS[athlete_name]
    rid = str(uuid.uuid4())

    if run_type == 'cross_train':
        activity = random.choice(XT_ACTIVITIES)
        duration = random.choice([30, 35, 40, 45, 60]) * 60
        rpe = random.choice([3, 4, 5, 6])
        out.append(
            f"INSERT INTO runs (id, athlete_id, run_date, run_type, duration_seconds, "
            f"effort_rpe, cross_train_activity, notes) VALUES "
            f"('{rid}', '{aid}', '{run_date.isoformat()}', 'cross_train', {duration}, {rpe}, "
            f"{sql_text(activity)}, NULL);"
        )
        return rid

    distance = run_distance_for(profile, run_type)
    duration = duration_for(distance, run_type, profile)
    rpe = {
        'easy':      random.choice([3, 4, 4, 5]),
        'long':      random.choice([5, 6, 6, 7]),
        'tempo':     random.choice([7, 7, 8]),
        'intervals': random.choice([8, 8, 9, 9]),
        'race':      random.choice([9, 9, 10]),
    }.get(run_type, 5)

    cadence = profile.get('cadence')
    cadence = (cadence + random.randint(-3, 3)) if cadence else None
    avg_hr  = (random.randint(155, 175)) if cadence else None  # only "watch" kids
    max_hr  = (avg_hr + random.randint(15, 25)) if avg_hr else None
    route   = random.choice(ROUTES) if run_type != 'race' else 'Race course'
    temp_f  = random.randint(68, 88)  # Tampa morning/afternoon
    humid   = random.randint(60, 92)
    wind    = round(random.uniform(2, 12), 1)
    dew     = temp_f - random.randint(4, 12)
    conds   = random.choice(['Clear', 'Partly cloudy', 'Overcast', 'Humid'])

    notes = None
    if run_type == 'race':
        notes = f'Race day at {race_meet}.'

    out.append(
        "INSERT INTO runs (id, athlete_id, run_date, run_type, distance_miles, "
        "duration_seconds, effort_rpe, avg_cadence, avg_hr, max_hr, route, "
        "conditions, temperature_f, wind_mph, humidity_percent, dewpoint_f, notes) VALUES "
        f"('{rid}', '{aid}', '{run_date.isoformat()}', '{run_type}', "
        f"{distance}, {duration}, {rpe}, {sql_num(cadence)}, {sql_num(avg_hr)}, "
        f"{sql_num(max_hr)}, {sql_text(route)}, {sql_text(conds)}, {temp_f}, {wind}, "
        f"{humid}, {dew}, {sql_text(notes)});"
    )

    # Emit a single segment matching run type (mirrors what log_run.html's simple
    # mode does on save). For tempo & intervals, emit a 3-segment breakdown
    # (warmup + tempo/interval + cooldown) so the pace-by-type tables have real
    # data to show.
    if run_type in ('tempo', 'intervals'):
        seg_type = 'tempo' if run_type == 'tempo' else 'interval'
        warmup_d = round(distance * 0.20, 2)
        cooldown_d = round(distance * 0.15, 2)
        work_d = round(distance - warmup_d - cooldown_d, 2)
        warmup_t = int(warmup_d * profile['easy_pace'] * random.uniform(0.97, 1.03))
        cooldown_t = int(cooldown_d * (profile['easy_pace'] + 30) * random.uniform(0.97, 1.03))
        work_t = duration - warmup_t - cooldown_t
        for order, (st, d, t) in enumerate([
            ('warmup', warmup_d, warmup_t),
            (seg_type, work_d, work_t),
            ('cooldown', cooldown_d, cooldown_t),
        ], start=1):
            out.append(
                "INSERT INTO run_segments (run_id, segment_order, segment_type, "
                "distance_miles, duration_seconds) VALUES "
                f"('{rid}', {order}, '{st}', {d}, {t});"
            )
    else:
        seg_type_map = {'easy': 'easy', 'long': 'easy', 'race': 'tempo'}
        st = seg_type_map.get(run_type)
        if st:
            out.append(
                "INSERT INTO run_segments (run_id, segment_order, segment_type, "
                "distance_miles, duration_seconds) VALUES "
                f"('{rid}', 1, '{st}', {distance}, {duration});"
            )
    return rid


def emit_runs(out):
    """For each athlete, walk 4 weeks of training history."""
    out.append('-- - Runs + segments -')
    for first, last, grade, gender, profile in ATHLETES:
        name = f'{first} {last}'

        # 5 running days per week + 1-2 cross-train, 1 rest day
        # Days of week: Mon=0..Sun=6
        # Pattern: Mon easy, Tue tempo/intervals (workout day), Wed easy,
        #          Thu cross-train, Fri easy, Sat long, Sun rest (no entry)
        for week in range(WEEKS_BACK):
            week_growth = profile['growth'] ** week
            week_profile = dict(profile)
            week_profile['weekly_mi'] = profile['weekly_mi'] * week_growth
            # Apply spike if this is the spike week
            if profile['spike'] and profile['spike'][0] == week:
                week_profile['weekly_mi'] *= profile['spike'][1]

            week_start = START_DATE + timedelta(days=week * 7)
            for day_offset, dow_type in enumerate([
                ('easy',        None),
                ('tempo',       'intervals' if week % 2 else 'tempo'),
                ('easy',        None),
                ('cross_train', None),
                ('easy',        None),
                ('long',        None),
                (None,          None),  # rest day
            ]):
                primary, alt = dow_type
                if not primary: continue
                run_type = primary if random.random() > 0.15 else (alt or primary)
                run_date = week_start + timedelta(days=day_offset)
                # Don't emit runs in the future
                if run_date > TODAY: continue
                emit_run(out, name, week_profile, run_date, run_type)
        out.append('')


def emit_race_meet(out):
    """One Saturday meet 10 days ago. Everyone races, varied finishes."""
    out.append('-- - Race meet -')
    meet_date = TODAY - timedelta(days=10)
    # If 10 days ago lands mid-week, push to nearest Saturday before it
    while meet_date.weekday() != 5:  # 5 = Saturday
        meet_date -= timedelta(days=1)

    # Build "race" runs for everyone, then a race_results row referencing each
    # Order athletes by random performance to assign finish places
    finish_order = list(ATHLETES)
    random.shuffle(finish_order)
    meet_name = 'Tampa Bay Invitational'
    course = 'Al Lopez Park'

    race_run_ids = []
    for place, (first, last, grade, gender, profile) in enumerate(finish_order, start=1):
        name = f'{first} {last}'
        # Replace any existing run on that date with the race
        run_id = emit_run(out, name, profile, meet_date, 'race', race_meet=meet_name)
        race_run_ids.append((run_id, place))

    out.append('-- race_results rows')
    for run_id, place in race_run_ids:
        team_place = place  # demo: order on team mirrors overall place
        out.append(
            "INSERT INTO race_results (run_id, meet_name, course_name, course_type, "
            "official_distance_meters, finish_place_overall, finish_place_team, "
            "team_score_total, opponents, conditions_notes) VALUES "
            f"('{run_id}', {sql_text(meet_name)}, {sql_text(course)}, 'xc', 3000, "
            f"{place * 3 + random.randint(-2, 2)}, {team_place}, "
            f"{len(ATHLETES) * 3 + random.randint(-5, 5)}, "
            f"'Plant, Hillsborough, Robinson', 'Warm, humid morning');"
        )
    out.append('')


ATHLETE_IDS = {}

def main():
    out = []
    out.append('-- ============================================================================')
    out.append('-- Rampello demo seed data')
    out.append(f'-- Generated by tools/generate_demo_data.py on {date.today().isoformat()}')
    out.append('-- ')
    out.append('-- All seeded athletes use @piratesdemo.test emails so cleanup is one line:')
    out.append("--   DELETE FROM athletes WHERE email LIKE '%@piratesdemo.test';")
    out.append('-- (cascades through runs, run_segments, race_results via FK ON DELETE CASCADE)')
    out.append('-- ============================================================================')
    out.append('')
    out.append('BEGIN;')
    out.append('')
    emit_athletes(out)
    emit_runs(out)
    emit_race_meet(out)
    out.append('COMMIT;')
    out.append('')
    print('\n'.join(out))


if __name__ == '__main__':
    main()
