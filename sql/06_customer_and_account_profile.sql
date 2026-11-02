-- =============================================================================
-- 06_customer_and_account_profile.sql
--
-- Who are the bank's customers, which of them borrow, and does who they are
-- (as opposed to how they behave, which is 07/08) say anything about risk?
--
-- Ages here are "as at 31 Dec 1998", the end of the data, unless I say
-- otherwise.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Customer base by gender and age band
-- -----------------------------------------------------------------------------
WITH c AS (
    SELECT
        gender,
        date_part('year', age(date '1998-12-31', birth_date))::int AS age
    FROM clean.client
)
SELECT
    CASE
        WHEN age < 18 THEN '0-17'
        WHEN age < 25 THEN '18-24'
        WHEN age < 35 THEN '25-34'
        WHEN age < 45 THEN '35-44'
        WHEN age < 55 THEN '45-54'
        WHEN age < 65 THEN '55-64'
        ELSE '65+'
    END                                       AS age_band,
    count(*) FILTER (WHERE gender = 'M')      AS men,
    count(*) FILTER (WHERE gender = 'F')      AS women,
    count(*)                                  AS total
FROM c
GROUP BY 1
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 2. Product take-up by region: loans, cards, standing orders
-- -----------------------------------------------------------------------------
SELECT
    d.region,
    count(DISTINCT a.account_id)                                       AS accounts,
    round(100.0 * count(DISTINCT l.account_id)  / count(DISTINCT a.account_id), 1) AS pct_with_loan,
    round(100.0 * count(DISTINCT cd_acct.account_id) / count(DISTINCT a.account_id), 1) AS pct_with_card,
    round(100.0 * count(DISTINCT po.account_id) / count(DISTINCT a.account_id), 1) AS pct_with_standing_order
FROM clean.account a
JOIN clean.district d               ON d.district_id = a.district_id
LEFT JOIN clean.loan l              ON l.account_id  = a.account_id
LEFT JOIN clean.permanent_order po  ON po.account_id = a.account_id
LEFT JOIN (
    SELECT DISTINCT disp.account_id
    FROM clean.disposition disp
    JOIN clean.card USING (disp_id)
) cd_acct                           ON cd_acct.account_id = a.account_id
GROUP BY d.region
ORDER BY accounts DESC;


-- -----------------------------------------------------------------------------
-- 3. The bank doesn't seem to lend to pensioners
--    740 accounts receive a pension. How many of them have a loan?
-- -----------------------------------------------------------------------------
WITH pension_accounts AS (
    SELECT DISTINCT account_id
    FROM clean.transactions
    WHERE purpose = 'Pension'
)
SELECT
    (SELECT count(*) FROM pension_accounts)                    AS accounts_receiving_pension,
    (SELECT count(*) FROM pension_accounts p JOIN clean.loan l USING (account_id))
                                                               AS of_which_have_a_loan;
-- Zero. Every loan goes to a working-age customer: the oldest borrower was
-- 61 at the time of the loan. Either that's credit policy, or the data was
-- filtered that way before it was released. Worth flagging either way.


-- -----------------------------------------------------------------------------
-- 4. Bad loan rate by the borrower's age at the time of the loan
-- -----------------------------------------------------------------------------
SELECT
    CASE
        WHEN age_at_loan < 25 THEN '1. under 25'
        WHEN age_at_loan < 35 THEN '2. 25-34'
        WHEN age_at_loan < 45 THEN '3. 35-44'
        WHEN age_at_loan < 55 THEN '4. 45-54'
        ELSE '5. 55+'
    END                                     AS age_band,
    count(*)                                AS loans,
    round(100.0 * avg(is_default::int), 1)  AS bad_loan_rate_pct
FROM analytics.loan_features
GROUP BY 1
ORDER BY 1;
-- Only a mild U-shape (8-14%). Age on its own isn't much of a signal.


-- -----------------------------------------------------------------------------
-- 5. Gender, statement frequency, and whether someone else uses the account
-- -----------------------------------------------------------------------------
SELECT 'gender' AS attribute, gender AS value, count(*) AS loans,
       round(100.0 * avg(is_default::int), 1) AS bad_loan_rate_pct
FROM analytics.loan_features GROUP BY gender
UNION ALL
SELECT 'statement_frequency', statement_frequency, count(*),
       round(100.0 * avg(is_default::int), 1)
FROM analytics.loan_features GROUP BY statement_frequency
UNION ALL
SELECT 'second_user_on_account', has_second_user::text, count(*),
       round(100.0 * avg(is_default::int), 1)
FROM analytics.loan_features GROUP BY has_second_user
UNION ALL
SELECT 'card_before_loan', card_before_loan, count(*),
       round(100.0 * avg(is_default::int), 1)
FROM analytics.loan_features GROUP BY card_before_loan
ORDER BY attribute, value;
-- Gender: basically no difference (10.5% vs 11.8%).
-- The one that jumps out: 145 loans are on accounts with a second authorised
-- user (usually a partner), and not a single one of them went bad, compared
-- with 14.2% for single-user accounts. Card holders show the same thing,
-- though there are only 36 of them, so I wouldn't lean on it too hard.


-- -----------------------------------------------------------------------------
-- 6. Region
-- -----------------------------------------------------------------------------
SELECT
    region,
    count(*)                                 AS loans,
    count(*) FILTER (WHERE is_default)       AS bad_loans,
    round(100.0 * avg(is_default::int), 1)   AS bad_loan_rate_pct
FROM analytics.loan_features
GROUP BY region
ORDER BY bad_loan_rate_pct DESC;
-- Ranges from 1.6% (north Bohemia) to 15.8% (west Bohemia), but with only
-- 57-129 loans per region, a handful of loans moves these numbers a lot.


-- -----------------------------------------------------------------------------
-- 7. Does the local economy matter? Correlation between district
--    unemployment / salary and the district's bad loan rate.
-- -----------------------------------------------------------------------------
WITH by_district AS (
    SELECT
        district_name,
        district_unemployment_96,
        district_avg_salary,
        count(*)               AS loans,
        avg(is_default::int)   AS bad_rate
    FROM analytics.loan_features
    GROUP BY district_name, district_unemployment_96, district_avg_salary
)
SELECT
    count(*)                                                       AS districts,
    round(corr(district_unemployment_96, bad_rate)::numeric, 3)    AS corr_unemployment_vs_bad_rate,
    round(corr(district_avg_salary, bad_rate)::numeric, 3)         AS corr_salary_vs_bad_rate
FROM by_district;
-- Both correlations are close to zero. District economics barely explain
-- anything here; what happens inside the account explains a lot more (08).
