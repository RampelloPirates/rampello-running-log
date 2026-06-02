-- ============================================================================
-- Seed last week (Mon 2026-05-25 → Sat 2026-05-30) for every active athlete
-- already in the database. Uses real athletes.id values so the runs show up
-- under whoever's already on the roster.
--
-- Pattern per athlete:
--   Mon easy / Tue tempo / Wed easy / Thu cross-train / Fri easy / Sat long
--   (Sun rest -- nothing inserted)
--
-- Volume and paces scale with grade (3-4 = beginner, 5-6 = middle, 7-8 = vet).
-- Tampa weather: 78-92°F, humid, mild wind. created_by = null (open-demo).
--
-- NOT IDEMPOTENT — running this twice creates duplicate runs for that week.
-- ============================================================================

DO $$
DECLARE
  ath              RECORD;
  d                DATE;
  rid              UUID;
  weekly_mi        NUMERIC;
  easy_pace        INT;
  workout_pace     INT;
  distance         NUMERIC;
  duration         INT;
  rt               TEXT;
  seg_type         TEXT;
  rpe              SMALLINT;
  cadence          SMALLINT;
  avg_hr_v         SMALLINT;
  max_hr_v         SMALLINT;
  temp_f_v         SMALLINT;
  dew_f_v          SMALLINT;
  humid_v          SMALLINT;
  wind_v           NUMERIC;
  cond_v           TEXT;
  route_v          TEXT;
  warmup_d         NUMERIC;
  cool_d           NUMERIC;
  tempo_d          NUMERIC;
  warmup_t         INT;
  cool_t           INT;
  tempo_t          INT;
  i                INT;

  days             DATE[] := ARRAY[
                      DATE '2026-05-25', DATE '2026-05-26', DATE '2026-05-27',
                      DATE '2026-05-28', DATE '2026-05-29', DATE '2026-05-30'
                    ];
  day_types        TEXT[] := ARRAY['easy','tempo','easy','cross_train','easy','long'];
  conds            TEXT[] := ARRAY['Clear','Partly cloudy','Overcast','Humid','Clear'];
  routes_easy      TEXT[] := ARRAY[
                      'Bayshore out & back','Hyde Park loop','Riverwalk + bridges',
                      'Davis Islands loop','Neighborhood — easy'
                    ];
  routes_workout   TEXT[] := ARRAY[
                      'Track at Plant HS','Al Lopez Park trails','Bayshore out & back'
                    ];
  xt_activities    TEXT[] := ARRAY[
                      'swimming','biking','elliptical','stretch + core','pool run'
                    ];
BEGIN
  FOR ath IN SELECT id, COALESCE(grade, 6) AS grade FROM athletes WHERE active = true LOOP
    weekly_mi    := CASE WHEN ath.grade <= 4 THEN 5
                         WHEN ath.grade <= 6 THEN 11
                         ELSE 18 END;
    easy_pace    := CASE WHEN ath.grade <= 4 THEN 720
                         WHEN ath.grade <= 6 THEN 640
                         ELSE 580 END;
    workout_pace := easy_pace - 80;

    FOR i IN 1..6 LOOP
      d  := days[i];
      rt := day_types[i];

      IF rt = 'cross_train' THEN
        rid := gen_random_uuid();
        INSERT INTO runs (
          id, athlete_id, run_date, time_of_day, run_type,
          duration_seconds, effort_rpe, cross_train_activity, notes, created_by
        ) VALUES (
          rid, ath.id, d, 'afternoon', 'cross_train',
          (30 + (random() * 30)::INT) * 60,
          (3 + (random() * 3)::INT)::SMALLINT,
          xt_activities[1 + (random() * (array_length(xt_activities,1) - 1))::INT],
          NULL, NULL
        );
        CONTINUE;
      END IF;

      IF rt = 'long' THEN
        distance := round((weekly_mi * (0.30 + random() * 0.10))::NUMERIC, 2);
        duration := (distance * (easy_pace + 30) * (0.95 + random() * 0.10))::INT;
        rpe      := (5 + (random() * 2)::INT)::SMALLINT;
        seg_type := 'easy';
      ELSIF rt = 'tempo' THEN
        distance := round((weekly_mi * (0.20 + random() * 0.08))::NUMERIC, 2);
        duration := (distance * ((workout_pace + easy_pace) / 2.0) * (0.95 + random() * 0.10))::INT;
        rpe      := (7 + (random() * 1)::INT)::SMALLINT;
        seg_type := 'tempo';
      ELSE
        distance := round((weekly_mi * (0.12 + random() * 0.08))::NUMERIC, 2);
        duration := (distance * easy_pace * (0.95 + random() * 0.10))::INT;
        rpe      := (3 + (random() * 2)::INT)::SMALLINT;
        seg_type := 'easy';
      END IF;

      cadence  := CASE WHEN ath.grade >= 7
                       THEN (176 + (random() * 6 - 3)::INT)::SMALLINT
                       ELSE NULL END;
      avg_hr_v := CASE WHEN cadence IS NOT NULL
                       THEN (155 + (random() * 20)::INT)::SMALLINT
                       ELSE NULL END;
      max_hr_v := CASE WHEN avg_hr_v IS NOT NULL
                       THEN (avg_hr_v + 15 + (random() * 10)::INT)::SMALLINT
                       ELSE NULL END;
      temp_f_v := (78 + (random() * 14)::INT)::SMALLINT;
      humid_v  := (65 + (random() * 25)::INT)::SMALLINT;
      dew_f_v  := (temp_f_v - 6 - (random() * 6)::INT)::SMALLINT;
      wind_v   := round((2 + random() * 10)::NUMERIC, 1);
      cond_v   := conds[1 + (random() * (array_length(conds,1) - 1))::INT];
      route_v  := CASE WHEN rt = 'tempo'
                       THEN routes_workout[1 + (random() * (array_length(routes_workout,1) - 1))::INT]
                       ELSE routes_easy[1 + (random() * (array_length(routes_easy,1) - 1))::INT]
                  END;

      rid := gen_random_uuid();
      INSERT INTO runs (
        id, athlete_id, run_date, time_of_day, run_type, distance_miles,
        duration_seconds, effort_rpe, avg_cadence, avg_hr, max_hr,
        route, conditions, temperature_f, wind_mph, humidity_percent,
        dewpoint_f, notes, created_by
      ) VALUES (
        rid, ath.id, d,
        CASE WHEN rt = 'tempo' THEN 'afternoon' ELSE 'morning' END,
        rt, distance, duration, rpe, cadence, avg_hr_v, max_hr_v,
        route_v, cond_v, temp_f_v, wind_v, humid_v, dew_f_v, NULL, NULL
      );

      IF rt = 'tempo' THEN
        warmup_d := round((distance * 0.20)::NUMERIC, 2);
        cool_d   := round((distance * 0.15)::NUMERIC, 2);
        tempo_d  := round((distance - warmup_d - cool_d)::NUMERIC, 2);
        warmup_t := (warmup_d * easy_pace)::INT;
        cool_t   := (cool_d * (easy_pace + 30))::INT;
        tempo_t  := duration - warmup_t - cool_t;
        INSERT INTO run_segments (run_id, segment_order, segment_type, distance_miles, duration_seconds)
        VALUES
          (rid, 1, 'warmup',   warmup_d, warmup_t),
          (rid, 2, 'tempo',    tempo_d,  tempo_t),
          (rid, 3, 'cooldown', cool_d,   cool_t);
      ELSE
        INSERT INTO run_segments (run_id, segment_order, segment_type, distance_miles, duration_seconds)
        VALUES (rid, 1, seg_type, distance, duration);
      END IF;
    END LOOP;
  END LOOP;
END $$;
