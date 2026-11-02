-- =============================================================================
-- 08_risk_drivers_and_scorecard.sql
--
-- Uses analytics.loan_features (built in 04, pre-loan data only) to answer:
--   1. Which signals separate good loans from bad ones, and by how much?
--   2. Can a handful of those signals be combined into a simple score that a
--      credit team could actually use?
--
-- The score at the end is deliberately simple, just points for each red flag.
-- A logistic regression in Python would be the natural next step, but a
-- points score is easy to explain to anyone, can be checked by hand, and
-- shows whether the signals hold up when combined.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Red flags: bad loan rate when the flag is present vs absent
--    lift = how many times the overall bad rate (11.1%) you get with the flag
-- -----------------------------------------------------------------------------
WITH flags AS (
    SELECT
        is_default,
        ever_overdrawn                       AS overdrawn_before_loan,
        (min_balance_last_90d < 10000)       AS balance_under_10k_last_90d,
        (payment_to_income_ratio > 0.20)     AS repayment_over_20pct_of_income,
        (amount > 200000)                    AS loan_over_200k,
        NOT pays_household_bills             AS no_household_bills_from_account,
        NOT has_second_user                  AS single_user_account
    FROM analytics.loan_features
),
long AS (
    SELECT 'Overdrawn before the loan'          AS red_flag, overdrawn_before_loan          AS flag, is_default FROM flags
    UNION ALL SELECT 'Balance under 10k in last 90 days',  balance_under_10k_last_90d,     is_default FROM flags
    UNION ALL SELECT 'Repayment over 20% of income',       repayment_over_20pct_of_income, is_default FROM flags
    UNION ALL SELECT 'Loan over 200k CZK',                 loan_over_200k,                 is_default FROM flags
    UNION ALL SELECT 'No household bills paid from account', no_household_bills_from_account, is_default FROM flags
    UNION ALL SELECT 'Single-user account',                single_user_account,            is_default FROM flags
)
SELECT
    red_flag,
    count(*) FILTER (WHERE flag)                                       AS loans_with_flag,
    round(100.0 * avg(is_default::int) FILTER (WHERE flag), 1)         AS bad_rate_with_flag,
    round(100.0 * avg(is_default::int) FILTER (WHERE NOT flag), 1)     AS bad_rate_without_flag,
    round(avg(is_default::int) FILTER (WHERE flag)
          / (SELECT avg(is_default::int) FROM flags), 1)               AS lift
FROM long
GROUP BY red_flag
ORDER BY lift DESC;
-- Overdrawn before the loan: 27 loans, all 27 went bad (lift 9x).
-- Balance under 10k in the 90 days before the loan: 43% bad (lift ~3.9x).
-- The others are weaker on their own (1.3x-1.7x), but they add up.
-- Single-user accounts: 14.2% bad vs 0% when there's a second user.


-- -----------------------------------------------------------------------------
-- 2. The numeric signals in quintiles, to see the shape of each relationship
--    rather than just one cut-off
-- -----------------------------------------------------------------------------
WITH q AS (
    SELECT
        is_default,
        min_balance_last_90d,    ntile(5) OVER (ORDER BY min_balance_last_90d)    AS q_min_bal,
        payment_to_income_ratio, ntile(5) OVER (ORDER BY payment_to_income_ratio) AS q_pti,
        balance_cover_months,    ntile(5) OVER (ORDER BY balance_cover_months)    AS q_cover,
        avg_balance,             ntile(5) OVER (ORDER BY avg_balance)             AS q_avg_bal
    FROM analytics.loan_features
)
SELECT 'Lowest balance, last 90 days' AS signal, q_min_bal AS quintile,
       round(min(min_balance_last_90d)) AS range_from, round(max(min_balance_last_90d)) AS range_to,
       count(*) AS loans, round(100.0 * avg(is_default::int), 1) AS bad_rate_pct
FROM q GROUP BY q_min_bal
UNION ALL
SELECT 'Repayment / monthly income', q_pti,
       min(payment_to_income_ratio), max(payment_to_income_ratio),
       count(*), round(100.0 * avg(is_default::int), 1)
FROM q GROUP BY q_pti
UNION ALL
SELECT 'Months of repayments covered by avg balance', q_cover,
       min(balance_cover_months), max(balance_cover_months),
       count(*), round(100.0 * avg(is_default::int), 1)
FROM q GROUP BY q_cover
UNION ALL
SELECT 'Average balance', q_avg_bal,
       round(min(avg_balance)), round(max(avg_balance)),
       count(*), round(100.0 * avg(is_default::int), 1)
FROM q GROUP BY q_avg_bal
ORDER BY signal, quintile;
-- Lowest balance in the last 90 days is the standout: the bottom fifth
-- (under ~13k CZK) goes bad 35.8% of the time; every other fifth is under 6%.
-- Repayment-to-income climbs steadily from 3.6% to 20.6%.


-- -----------------------------------------------------------------------------
-- 3. A simple risk score
--
--    +2  overdrawn at any point before the loan
--    +2  lowest balance in the last 90 days under 10,000 CZK
--    +1  monthly repayment over 20% of average monthly income
--    +1  loan over 200,000 CZK
--    +1  no household bills paid from the account
--    +1  single-user account
--
--    Max score is 8. The two balance flags get double weight because they're
--    far stronger than the rest (section 1).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS analytics.loan_risk_score CASCADE;

CREATE TABLE analytics.loan_risk_score AS
SELECT
    loan_id,
    account_id,
    client_id,
    loan_date,
    amount,
    status_code,
    is_default,
    score,
    CASE
        WHEN score <= 1 THEN '1. Low'
        WHEN score <= 3 THEN '2. Medium'
        WHEN score <= 5 THEN '3. High'
        ELSE                 '4. Very high'
    END AS risk_band
FROM (
    SELECT
        *,
          2 * ever_overdrawn::int
        + 2 * (min_balance_last_90d < 10000)::int
        +     (payment_to_income_ratio > 0.20)::int
        +     (amount > 200000)::int
        +     (NOT pays_household_bills)::int
        +     (NOT has_second_user)::int          AS score
    FROM analytics.loan_features
) s;

ALTER TABLE analytics.loan_risk_score ADD PRIMARY KEY (loan_id);


-- Does the score rank risk properly? Bad rate should climb with the score.
SELECT
    score,
    count(*)                                AS loans,
    count(*) FILTER (WHERE is_default)      AS bad_loans,
    round(100.0 * avg(is_default::int), 1)  AS bad_rate_pct
FROM analytics.loan_risk_score
GROUP BY score
ORDER BY score;
-- It does, at every step: 0% at score 0, 2.5% at 1, 11.7% at 3,
-- 34.9% at 4, and 100% from 7 up.


-- Summary by band, with how much of all bad loans each band catches
-- (cumulative from the riskiest band down)
SELECT
    risk_band,
    count(*)                                                     AS loans,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)           AS pct_of_loans,
    count(*) FILTER (WHERE is_default)                           AS bad_loans,
    round(100.0 * avg(is_default::int), 1)                       AS bad_rate_pct,
    round(100.0 * sum(count(*) FILTER (WHERE is_default)) OVER (ORDER BY risk_band DESC)
          / sum(count(*) FILTER (WHERE is_default)) OVER (), 1)  AS cumulative_pct_of_bad_loans_caught
FROM analytics.loan_risk_score
GROUP BY risk_band
ORDER BY risk_band;
-- The High and Very high bands are 87 loans (12.8% of the book) but hold
-- 47 of the 76 bad loans (62%). Low risk is 289 loans with only 6 bad (2.1%).
--
-- Honest caveat: I picked the thresholds on the same 682 loans I'm scoring,
-- so these numbers are optimistic. Before anyone used this for real it
-- would need testing on loans it hasn't seen, e.g. build it on 1993-1996
-- loans and check it on 1997-1998.


-- -----------------------------------------------------------------------------
-- 4. What does the score miss? The bad loans that landed in the Low band
-- -----------------------------------------------------------------------------
SELECT
    r.loan_id,
    r.score,
    f.amount,
    f.payment_to_income_ratio,
    round(f.min_balance_last_90d) AS min_balance_last_90d,
    round(f.avg_balance)          AS avg_balance,
    f.age_at_loan,
    f.region
FROM analytics.loan_risk_score r
JOIN analytics.loan_features f USING (loan_id)
WHERE r.is_default AND r.risk_band = '1. Low'
ORDER BY r.score, f.amount DESC;
-- Six loans with healthy-looking accounts that still went bad. Nothing in
-- the transaction history flagged them, which is roughly the limit of what
-- account behaviour alone can tell you. Things like job loss happen
-- outside the data.
