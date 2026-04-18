---Preview User_profile
SELECT *
from `workspace`.`default`.`bright_tv_dataset`;
 

---Preview Viewership
SELECT *
 FROM `workspace`.`default`.`bright_tv_data_viewership`;


 ---Check Column types
DESCRIBE `workspace`.`default`.`bright_tv_data_viewership`;

DESCRIBE `workspace`.`default`.`bright_tv_dataset`;


-- Null counts — viewership
SELECT
  SUM(CASE WHEN UserID       IS NULL THEN 1 ELSE 0 END) AS null_userid,
  SUM(CASE WHEN Channel2     IS NULL THEN 1 ELSE 0 END) AS null_channel,
  SUM(CASE WHEN RecordDate2  IS NULL THEN 1 ELSE 0 END) AS null_date,
  SUM(CASE WHEN Duration2    IS NULL THEN 1 ELSE 0 END) AS null_duration
FROM `workspace`.`default`.`bright_tv_data_viewership`;


-- Null counts — user profiles
SELECT
  SUM(CASE WHEN UserID   IS NULL THEN 1 ELSE 0 END) AS null_userid,
  SUM(CASE WHEN Gender   IS NULL THEN 1 ELSE 0 END) AS null_gender,
  SUM(CASE WHEN Race     IS NULL THEN 1 ELSE 0 END) AS null_race,
  SUM(CASE WHEN Age      IS NULL THEN 1 ELSE 0 END) AS null_age,
  SUM(CASE WHEN Province IS NULL THEN 1 ELSE 0 END) AS null_province
FROM `workspace`.`default`.`bright_tv_dataset`;

-- ================================================================
-- STEP 3 — CREATE CLEANED BASE VIEWS
-- Materialise once; all analysis queries reference these views.
-- ================================================================

-- 3a: viewership cleaned with SA time and duration in minutes
CREATE OR REPLACE TEMP VIEW viewership AS
SELECT
  v.UserID,
  v.Channel2                                               AS channel,

  -- UTC → SA time (UTC+2)
  v.RecordDate2 + INTERVAL 2 HOURS                        AS record_date_sa,
  HOUR  (v.RecordDate2 + INTERVAL 2 HOURS)                AS hour_sa,
  MONTH (v.RecordDate2 + INTERVAL 2 HOURS)                AS month_num,
  DATE_FORMAT(v.RecordDate2 + INTERVAL 2 HOURS, 'EEEE')  AS day_of_week,
  DATE_FORMAT(v.RecordDate2 + INTERVAL 2 HOURS, 'MMMM')  AS month_name,
  TO_DATE(v.RecordDate2 + INTERVAL 2 HOURS)               AS view_date,
  WEEKOFYEAR(v.RecordDate2 + INTERVAL 2 HOURS)            AS week_num,

  -- Duration: handle both string "HH:MM:SS" and Excel decimal formats
  CASE
    WHEN v.Duration2 RLIKE '^[0-9]+:[0-9]+:[0-9]+$'
      THEN (
          CAST(SPLIT(v.Duration2, ':')[0] AS DOUBLE) * 60.0
        + CAST(SPLIT(v.Duration2, ':')[1] AS DOUBLE)
        + CAST(SPLIT(v.Duration2, ':')[2] AS DOUBLE) / 60.0
      )
    WHEN v.Duration2 RLIKE '^[0-9]*\\.?[0-9]+$'
      -- Excel serial time fraction → minutes
      THEN ROUND(CAST(v.Duration2 AS DOUBLE) * 24.0 * 60.0, 4)
    ELSE NULL
  END                                                      AS duration_mins

FROM `workspace`.`default`.`bright_tv_data_viewership` v
WHERE v.RecordDate2 IS NOT NULL;



-- 3b: merged view — viewership + user profiles + age bands
CREATE OR REPLACE TEMP VIEW merged AS
SELECT
  v.*,
  u.Gender,
  u.Race,
  u.Age,
  u.Province,
  u.`Social Media Handle`,

  CASE
    WHEN u.Age BETWEEN  0 AND 17 THEN '<18'
    WHEN u.Age BETWEEN 18 AND 25 THEN '18-25'
    WHEN u.Age BETWEEN 26 AND 35 THEN '26-35'
    WHEN u.Age BETWEEN 36 AND 45 THEN '36-45'
    WHEN u.Age BETWEEN 46 AND 60 THEN '46-60'
    ELSE '60+'
  END                                                      AS age_group,

  CASE
    WHEN v.hour_sa BETWEEN  1 AND  5 THEN 'Dead hours  01-05'
    WHEN v.hour_sa BETWEEN  6 AND 11 THEN 'Morning     06-11'
    WHEN v.hour_sa BETWEEN 12 AND 19 THEN 'Prime time  12-19'
    WHEN v.hour_sa BETWEEN 20 AND 23 THEN 'Late night  20-23'
    ELSE                                   'Midnight    00'
  END                                                      AS time_band,

  CASE
    WHEN v.channel IN (
        'Supersport Live Events',
        'SuperSport Blitz',
        'ICC Cricket World Cup 2011',
        'DStv Events 1'
    ) THEN 'Sport / Events'
    WHEN v.channel IN ('Cartoon Network','Boomerang')
      THEN 'Kids'
    WHEN v.channel IN ('Trace TV','Channel O','Vuzu')
      THEN 'Music / Youth'
    WHEN v.channel IN (
        'CNN','E! Entertainment','M-Net','Africa Magic','SawSee'
    ) THEN 'Entertainment / News'
    ELSE 'Other'
  END                                                      AS genre

FROM viewership v
LEFT JOIN `workspace`.`default`.`bright_tv_dataset` u ON v.UserID = u.UserID;



-- ================================================================
-- SECTION 2 — EXECUTIVE SUMMARY
-- ================================================================

-- 2.1  Top-line dashboard metrics

SELECT
  u.registered_users,
  u.active_users,
  u.registered_users - u.active_users AS dormant_users,
  ROUND(100.0 * u.active_users / u.registered_users, 1) AS engagement_rate_pct,

  COUNT(*)                                  AS total_sessions,
  COUNT(DISTINCT m.UserID)                  AS active_viewers,
  ROUND(SUM(duration_mins) / 60.0, 1)       AS total_viewing_hours,
  ROUND(AVG(duration_mins), 2)              AS avg_session_mins,
  COUNT(DISTINCT channel)                   AS unique_channels,
  COUNT(DISTINCT view_date)                 AS days_with_activity

FROM merged m
CROSS JOIN (
  SELECT
    COUNT(DISTINCT UserID) AS registered_users,
    (SELECT COUNT(DISTINCT UserID) FROM viewership) AS active_users
  FROM `workspace`.`default`.`bright_tv_dataset`
) u
GROUP BY
  u.registered_users,
  u.active_users;

-- ================================================================
-- SECTION 3 — USER & USAGE TRENDS
-- ================================================================

-- 3.1  Daily session trend
SELECT
  view_date,
  day_of_week,
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(SUM(duration_mins), 1)      AS total_mins,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins
FROM merged
GROUP BY view_date, day_of_week
ORDER BY view_date;



-- 3.2  Sessions by month
SELECT
  month_num,
  month_name,
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(SUM(duration_mins)/60.0,1)  AS total_hours,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins
FROM merged
GROUP BY month_num, month_name
ORDER BY month_num;



-- 3.3  Sessions by day of week (Mon–Sun sorted)
SELECT
  day_of_week,
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM merged
GROUP BY day_of_week
ORDER BY
  CASE day_of_week
    WHEN 'Monday'    THEN 1
    WHEN 'Tuesday'   THEN 2
    WHEN 'Wednesday' THEN 3
    WHEN 'Thursday'  THEN 4
    WHEN 'Friday'    THEN 5
    WHEN 'Saturday'  THEN 6
    ELSE 7
  END;



-- 3.4  Sessions by hour of day (SA time)
SELECT
  hour_sa,
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM merged
GROUP BY hour_sa
ORDER BY hour_sa;



-- 3.5  Sessions by time band
SELECT
  time_band,
  COUNT(*)                          AS sessions,
  ROUND(AVG(duration_mins), 2)      AS avg_mins,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM merged
GROUP BY time_band
ORDER BY sessions DESC;



-- 3.6  Weekly trend with week-over-week growth
-- LAG applied in outer query after aggregation
SELECT
  week_num,
  sessions,
  unique_users,
  total_hours,
  LAG(sessions) OVER (ORDER BY week_num)  AS prev_week_sessions,
  ROUND(
    100.0 * (sessions - LAG(sessions) OVER (ORDER BY week_num))
          / NULLIF(LAG(sessions) OVER (ORDER BY week_num), 0),
  1)                                       AS wow_growth_pct
FROM (
  SELECT
    week_num,
    COUNT(*)                              AS sessions,
    COUNT(DISTINCT UserID)                AS unique_users,
    ROUND(SUM(duration_mins)/60.0, 1)    AS total_hours
  FROM merged
  GROUP BY week_num
) weekly
ORDER BY week_num;



-- ================================================================
-- SECTION 4 — CHANNEL ANALYSIS
-- ================================================================

-- 4.1  Overall channel performance
SELECT
  channel,                                                               ----Overall channel performance
  age_group,                                                             ----Channel performance by age group
  hour_sa,                                                               ---Channel performance by hour
  genre,                                                                 ---Genre-level consumption summary                                                         
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_viewers,
  ROUND(SUM(duration_mins)/60.0,1)  AS total_hours,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_sessions,
  SUM(CASE WHEN day_of_week='Monday'    THEN 1 ELSE 0 END) AS monday,    ------Channel sessions by day of week (pivot)
  SUM(CASE WHEN day_of_week='Tuesday'   THEN 1 ELSE 0 END) AS tuesday,
  SUM(CASE WHEN day_of_week='Wednesday' THEN 1 ELSE 0 END) AS wednesday,
  SUM(CASE WHEN day_of_week='Thursday'  THEN 1 ELSE 0 END) AS thursday,
  SUM(CASE WHEN day_of_week='Friday'    THEN 1 ELSE 0 END) AS friday,
  SUM(CASE WHEN day_of_week='Saturday'  THEN 1 ELSE 0 END) AS saturday,
  SUM(CASE WHEN day_of_week='Sunday'    THEN 1 ELSE 0 END) AS sunday
FROM merged
WHERE age_group IS NOT NULL
GROUP BY channel,
         age_group,
         hour_sa,
         genre
ORDER BY channel, sessions DESC;



-- ================================================================
-- SECTION 5 — DEMOGRAPHIC ANALYSIS
-- ================================================================

-- 5.1  Sessions by age group
SELECT
  age_group,                                                          ---Sessions by age group
  Gender,                                                             ---Sessions by gender  
  Race,                                                               ---Sessions by race
  Province,                                                           ---Sessions by province
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(AVG(duration_mins), 2)      AS avg_session_mins,
  CASE WHEN Race = 'indian_asian' THEN 'Indian / Asian' ELSE 'All other' END AS segment, --Race viewing depth comparison
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM merged
WHERE age_group IS NOT NULL AND Gender IN ('male','female') AND Race IS NOT NULL AND Race != '' AND Province IS NOT NULL AND Province != '' 
GROUP BY age_group,
         Gender,
         Race,
         Province,
         CASE WHEN Race = 'indian_asian' THEN 'Indian / Asian' ELSE 'All other' END
ORDER BY
    Province, sessions DESC,
    CASE age_group
    WHEN '<18'   THEN 1
    WHEN '18-25' THEN 2
    WHEN '26-35' THEN 3
    WHEN '36-45' THEN 4
    WHEN '46-60' THEN 5
    ELSE 6
  END;


-- ================================================================
-- SECTION 6 — LOW CONSUMPTION DAYS ANALYSIS
-- ================================================================

-- 6.1  Top 10 lowest-consumption days
SELECT
  view_date,
  day_of_week,
  COUNT(*)                          AS sessions,
  COUNT(DISTINCT UserID)            AS unique_users,
  ROUND(AVG(duration_mins), 2)      AS avg_mins
FROM merged
GROUP BY view_date, day_of_week
ORDER BY sessions ASC
LIMIT 10;



-- 6.2  Best channels on Mondays (content programming guide)
SELECT
  channel,
  COUNT(*)                          AS monday_sessions,
  COUNT(DISTINCT UserID)            AS unique_viewers,
  ROUND(AVG(duration_mins), 2)      AS avg_mins
FROM merged
WHERE day_of_week = 'Monday'
GROUP BY channel
ORDER BY monday_sessions DESC;



-- 6.3  Monday channel index vs full-week share
WITH monday_ch AS (
  SELECT channel, COUNT(*) AS mon_sessions
  FROM merged WHERE day_of_week = 'Monday'
  GROUP BY channel
),
total_ch AS (
  SELECT channel, COUNT(*) AS all_sessions
  FROM merged GROUP BY channel
),
totals AS (
  SELECT
    COUNT(*)                                                  AS grand_total,
    SUM(CASE WHEN day_of_week='Monday' THEN 1 ELSE 0 END)    AS monday_total
  FROM merged
)
SELECT
  t.channel,
  m.mon_sessions,
  t.all_sessions,
  ROUND(100.0 * m.mon_sessions / tot.monday_total, 1)        AS share_of_monday_pct,
  ROUND(100.0 * t.all_sessions / tot.grand_total,  1)        AS share_of_all_pct,
  ROUND(
    (1.0 * m.mon_sessions / NULLIF(tot.monday_total, 0))
  / (1.0 * t.all_sessions / NULLIF(tot.grand_total,  0)),
  2)                                                         AS monday_index
FROM total_ch  t
JOIN monday_ch m   ON t.channel = m.channel
CROSS JOIN totals  tot
ORDER BY monday_index DESC;



-- 6.4  Hourly profile on Mondays
SELECT
  hour_sa,
  COUNT(*)                                          AS monday_sessions,
  ROUND(AVG(duration_mins), 2)                      AS monday_avg_mins,
  SUM(COUNT(*)) OVER ()                             AS monday_total,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_monday
FROM merged
WHERE day_of_week = 'Monday'
GROUP BY hour_sa
ORDER BY hour_sa;



-- 6.5  Content preferences on low-traffic days by age group
SELECT
  day_of_week,
  age_group,
  channel,
  COUNT(*) AS sessions
FROM merged
WHERE day_of_week IN ('Monday','Tuesday')
  AND age_group IS NOT NULL
GROUP BY day_of_week, age_group, channel
ORDER BY day_of_week, age_group, sessions DESC;



-- 6.6  Weekday vs weekend time band comparison
SELECT
  CASE WHEN day_of_week IN ('Saturday','Sunday') THEN 'Weekend' ELSE 'Weekday' END AS day_type,
  time_band,
  COUNT(*)                          AS sessions,
  ROUND(AVG(duration_mins), 2)      AS avg_mins
FROM merged
GROUP BY
  CASE WHEN day_of_week IN ('Saturday','Sunday') THEN 'Weekend' ELSE 'Weekday' END,
  time_band
ORDER BY sessions DESC;



-- ================================================================
-- SECTION 7 — GROWTH & CVM INITIATIVES
-- ================================================================

-- 7.1  Dormant users — never watched (win-back list)

SELECT
  v.UserID,
  u.UserID,
  u.Name,
  u.Surname,
  u.Email,
  u.Gender,
  u.Age,
  u.Province,
  u.`Social Media Handle`,
  COUNT(*) AS dormant_users,                                 ---Dormant user count by province (targeting priority)
  COUNT(*)                                  AS total_sessions,
  COUNT(DISTINCT channel)                   AS channels_watched,
  COUNT(DISTINCT view_date)                 AS active_days,
  ROUND(SUM(duration_mins)/60.0, 2)        AS total_hours,
  ROUND(AVG(duration_mins), 2)             AS avg_session_mins,
  MIN(record_date_sa)                       AS first_view_sa,
  MAX(record_date_sa)                       AS last_view_sa,
  DATEDIFF(
    TO_DATE(MAX(record_date_sa)),
    TO_DATE(MIN(record_date_sa))
  )                                         AS days_as_viewer,
  CASE
    WHEN COUNT(*) >= 10 THEN 'High'
    WHEN COUNT(*) >=  3 THEN 'Medium'
    ELSE 'Low'
    END                                       AS engagement_tier
FROM `workspace`.`default`.`bright_tv_dataset` u
LEFT JOIN viewership v ON u.UserID = v.UserID
WHERE 
  u.Province IS NOT NULL AND u.Province != '' AND u.`Social Media Handle` IS NOT NULL AND u.`Social Media Handle` != ''
GROUP BY 
  v.UserID,
  u.UserID,
  u.Name,
  u.Surname,
  u.Email,
  u.Gender,
  u.Age,
  u.Province,
  u.`Social Media Handle`
ORDER BY u.Province, 
         u.Age,
         dormant_users DESC,
         total_sessions DESC;



-- 7.5  Top 20 most valuable users by total viewing hours
SELECT
  m.UserID,
  u.Gender,
  u.Age,
  u.Province,
  COUNT(*)                                  AS sessions,
  ROUND(SUM(m.duration_mins)/60.0, 1)      AS total_hours,
  COUNT(DISTINCT m.channel)                 AS channels_watched
FROM merged        m
JOIN `workspace`.`default`.`bright_tv_dataset` u ON m.UserID = u.UserID
GROUP BY m.UserID, u.Gender, u.Age, u.Province
ORDER BY total_hours DESC
LIMIT 20;



-- 7.6  Female user channel preferences (female audience strategy)
SELECT
  channel,
  COUNT(*)                          AS female_sessions,
  ROUND(AVG(duration_mins), 2)      AS avg_mins
FROM merged
WHERE Gender = 'female'
GROUP BY channel
ORDER BY female_sessions DESC;



-- 7.7  Youth (18-25) channel preferences
SELECT
  channel,
  COUNT(*)                          AS sessions,
  ROUND(AVG(duration_mins), 2)      AS avg_mins
FROM merged
WHERE age_group = '18-25'
GROUP BY channel
ORDER BY sessions DESC;



-- 7.8  Province activation rate — penetration analysis
-- COALESCE replaces T-SQL ISNULL
WITH reg AS (
  SELECT Province, COUNT(*) AS registered
  FROM `workspace`.`default`.`bright_tv_dataset`
  WHERE Province IS NOT NULL AND Province != ''
  GROUP BY Province
),
act AS (
  SELECT u.Province, COUNT(DISTINCT v.UserID) AS active
  FROM viewership  v
  JOIN `workspace`.`default`.`bright_tv_dataset`   u ON v.UserID = u.UserID
  WHERE u.Province IS NOT NULL AND u.Province != ''
  GROUP BY u.Province
)
SELECT
  r.Province,
  r.registered,
  COALESCE(a.active, 0)                                   AS active_users,
  r.registered - COALESCE(a.active, 0)                    AS dormant_users,
  ROUND(100.0 * COALESCE(a.active,0) / NULLIF(r.registered,0), 1) AS activation_rate_pct
FROM reg r
LEFT JOIN act a ON r.Province = a.Province
ORDER BY activation_rate_pct ASC;


-- ================================================================
-- END OF SCRIPT — 31 queries, Databricks / Spark SQL native
-- ==============================================================
