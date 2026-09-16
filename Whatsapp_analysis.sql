
-- ---------- 1. SCHEMA ----------
DROP TABLE IF EXISTS contacts;
CREATE TABLE contacts (
    contact_id      TEXT PRIMARY KEY,
    city_tier       TEXT,
    age_group       TEXT,
    device_type     TEXT,
    signup_channel  TEXT,
    tenure_days     INTEGER
);

DROP TABLE IF EXISTS campaign_events;
CREATE TABLE campaign_events (
    message_id            TEXT PRIMARY KEY,
    contact_id             TEXT REFERENCES contacts(contact_id),
    send_date              DATE,
    send_hour              INTEGER,
    day_of_week            TEXT,
    message_type           TEXT,
    delivered               INTEGER,   -- 0/1
    read_                    INTEGER,   -- 0/1
    responded               INTEGER,   -- 0/1
    converted               INTEGER,   -- 0/1
    opted_out               INTEGER,   -- 0/1
    time_to_read_min        REAL,
    time_to_response_hr     REAL
);

-- ---------- 2. OVERALL FUNNEL ----------
SELECT
    COUNT(*)                                   AS total_sent,
    SUM(delivered)                             AS total_delivered,
    SUM(read_)                                  AS total_read,
    SUM(responded)                             AS total_responded,
    SUM(converted)                             AS total_converted,
    SUM(opted_out)                             AS total_opted_out,
    ROUND(100.0 * SUM(delivered) / COUNT(*), 1)         AS delivery_rate_pct,
    ROUND(100.0 * SUM(read_) / NULLIF(SUM(delivered),0), 1) AS read_rate_pct,
    ROUND(100.0 * SUM(responded) / NULLIF(SUM(read_),0), 1) AS response_rate_pct,
    ROUND(100.0 * SUM(converted) / NULLIF(SUM(responded),0), 1) AS conversion_rate_pct,
    ROUND(100.0 * SUM(opted_out) / NULLIF(SUM(delivered),0), 1)  AS optout_rate_pct
FROM campaign_events;


-- ---------- 3. FUNNEL BY MESSAGE TYPE ----------
SELECT
    message_type,
    COUNT(*)                                             AS sent,
    ROUND(100.0 * SUM(delivered) / COUNT(*), 1)          AS delivery_rate_pct,
    ROUND(100.0 * SUM(read_) / NULLIF(SUM(delivered),0),1) AS read_rate_pct,
    ROUND(100.0 * SUM(responded) / NULLIF(SUM(read_),0),1) AS response_rate_pct,
    ROUND(100.0 * SUM(converted) / NULLIF(SUM(responded),0),1) AS conversion_rate_pct
FROM campaign_events
GROUP BY message_type
ORDER BY conversion_rate_pct DESC;


-- ---------- 4. BEST SEND WINDOW (day-of-week x hour bucket) ----------
SELECT
    day_of_week,
    CASE
        WHEN send_hour BETWEEN 6 AND 11  THEN 'Morning (6-11)'
        WHEN send_hour BETWEEN 12 AND 17 THEN 'Afternoon (12-17)'
        WHEN send_hour BETWEEN 18 AND 22 THEN 'Evening (18-22)'
        ELSE 'Late Night (23-5)'
    END AS send_window,
    COUNT(*) AS sent,
    ROUND(100.0 * SUM(read_) / NULLIF(SUM(delivered),0), 1)  AS read_rate_pct,
    ROUND(100.0 * SUM(responded) / NULLIF(SUM(read_),0), 1)  AS response_rate_pct
FROM campaign_events
GROUP BY day_of_week, send_window
ORDER BY response_rate_pct DESC
LIMIT 10;


-- ---------- 5. SEGMENT PERFORMANCE (join to contacts) ----------
SELECT
    c.city_tier,
    c.age_group,
    c.signup_channel,
    COUNT(*)                                                    AS sent,
    ROUND(100.0 * SUM(e.responded) / NULLIF(SUM(e.read),0), 1)  AS response_rate_pct,
    ROUND(100.0 * SUM(e.converted) / NULLIF(SUM(e.responded),0), 1) AS conversion_rate_pct,
    ROUND(100.0 * SUM(e.opted_out) / NULLIF(SUM(e.delivered),0), 1) AS optout_rate_pct
FROM campaign_events e
JOIN contacts c ON c.contact_id = e.contact_id
GROUP BY c.city_tier, c.age_group, c.signup_channel
HAVING COUNT(*) >= 5
ORDER BY conversion_rate_pct DESC;


-- ---------- 6. HIGH OPT-OUT RISK CONTACTS (for suppression lists) ----------
SELECT
    c.contact_id,
    c.city_tier,
    c.signup_channel,
    COUNT(*)                                            AS messages_received,
    SUM(e.opted_out)                                    AS optouts,
    ROUND(100.0 * SUM(e.opted_out) / COUNT(*), 1)        AS optout_rate_pct
FROM campaign_events e
JOIN contacts c ON c.contact_id = e.contact_id
GROUP BY c.contact_id, c.city_tier, c.signup_channel
HAVING SUM(e.opted_out) > 0
ORDER BY optout_rate_pct DESC;


-- ---------- 7. MONTH-OVER-MONTH TREND ----------
SELECT
    strftime('%Y-%m', send_date)                                  AS month,   -- MySQL: DATE_FORMAT(send_date,'%Y-%m')
    COUNT(*)                                                      AS sent,
    ROUND(100.0 * SUM(read_) / NULLIF(SUM(delivered),0), 1)        AS read_rate_pct,
    ROUND(100.0 * SUM(converted) / NULLIF(SUM(responded),0), 1)   AS conversion_rate_pct
FROM campaign_events
GROUP BY month
ORDER BY month;


-- ---------- 8. RFM-STYLE ENGAGEMENT SCORE PER CONTACT ----------

SELECT
    c.contact_id,
    COUNT(*)                                              AS total_messages,
    SUM(e.responded)                                      AS total_responses,
    SUM(e.converted)                                      AS total_conversions,
    MAX(e.send_date)                                      AS last_contacted,
    ROUND(1.0 * SUM(e.responded) / COUNT(*), 2)           AS response_ratio,
    ROUND(1.0 * SUM(e.converted) / NULLIF(SUM(e.responded),0), 2) AS conversion_ratio,
    (SUM(e.responded) * 2 + SUM(e.converted) * 5 - SUM(e.opted_out) * 10) AS engagement_score
FROM campaign_events e
JOIN contacts c ON c.contact_id = e.contact_id
GROUP BY c.contact_id
ORDER BY engagement_score DESC;
