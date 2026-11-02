-- =============================================================================
-- 04_loan_risk_features.sql
--
-- Builds analytics.loan_features: one row per loan, describing the customer
-- and how their account behaved BEFORE the loan was granted.
--
-- The "before" part matters more than anything else in this project. If I
-- used every transaction, a customer who later fell into arrears would look
-- risky because of the arrears themselves (missed payments, overdrafts after
-- the loan). That's data leakage, and it would make the analysis look much
-- better than it really is. A bank deciding whether to approve a loan only
-- has the history up to that day, so that's all I use:
--
--     t.trans_date < l.loan_date
--
-- Every account has at least 102 days of history before its loan (median
-- around 13 months), so there's always something to work with.
--
-- I build this straight after cleaning because most of the analysis scripts
-- that follow (06, 08, 10) read from it. It would also be the starting point
-- for a model in Python.
-- =============================================================================

DROP TABLE IF EXISTS analytics.loan_features CASCADE;

CREATE TABLE analytics.loan_features AS
WITH
-- The account owner is the person the loan really belongs to
loan_owner AS (
    SELECT
        l.loan_id,
        c.client_id,
        c.gender,
        date_part('year', age(l.loan_date, c.birth_date))::int AS age_at_loan
    FROM clean.loan l
    JOIN clean.disposition d ON d.account_id = l.account_id AND d.role = 'Owner'
    JOIN clean.client c      ON c.client_id  = d.client_id
),

-- Does anyone else have access to the account? (a partner, family member...)
account_users AS (
    SELECT account_id, count(*) AS users_on_account
    FROM clean.disposition
    GROUP BY account_id
),

-- Highest card held by anyone on the account, issued before the loan
card_before_loan AS (
    SELECT
        l.loan_id,
        max(CASE cd.card_type WHEN 'gold' THEN 3 WHEN 'classic' THEN 2 WHEN 'junior' THEN 1 END) AS card_rank
    FROM clean.loan l
    JOIN clean.disposition d ON d.account_id = l.account_id
    JOIN clean.card cd       ON cd.disp_id   = d.disp_id AND cd.issued_date < l.loan_date
    GROUP BY l.loan_id
),

-- Every transaction on the account before the loan date
pre_loan_txn AS (
    SELECT l.loan_id, t.*
    FROM clean.loan l
    JOIN clean.transactions t
      ON t.account_id = l.account_id
     AND t.trans_date < l.loan_date
),

-- Balance and overdraft behaviour across the whole pre-loan history
balance_stats AS (
    SELECT
        loan_id,
        count(*)                                                        AS n_transactions,
        round(avg(balance), 2)                                          AS avg_balance,
        min(balance)                                                    AS min_balance,
        round(stddev_samp(balance), 2)                                  AS balance_volatility,
        count(*) FILTER (WHERE balance < 0)                             AS negative_balance_txns,
        count(*) FILTER (WHERE purpose = 'Penalty interest (overdrawn)') AS penalty_interest_charges,
        round(
            count(*) FILTER (WHERE operation = 'Cash withdrawal')::numeric
            / nullif(count(*) FILTER (WHERE direction = 'Debit'), 0), 3)  AS cash_withdrawal_share,
        min(trans_date)                                                 AS first_txn_date
    FROM pre_loan_txn
    GROUP BY loan_id
),

-- Balance on the day before the loan (latest transaction wins)
last_balance AS (
    SELECT DISTINCT ON (loan_id)
        loan_id,
        balance AS balance_before_loan
    FROM pre_loan_txn
    ORDER BY loan_id, trans_date DESC, trans_id DESC
),

-- The last 90 days before the loan: has the customer been squeezed recently?
recent_stats AS (
    SELECT
        p.loan_id,
        min(p.balance)  AS min_balance_last_90d,
        round(avg(p.balance), 2) AS avg_balance_last_90d
    FROM pre_loan_txn p
    JOIN clean.loan l USING (loan_id)
    WHERE p.trans_date >= l.loan_date - 90
    GROUP BY p.loan_id
),

-- Money in and out per calendar month. Interest credited by the bank isn't
-- really "income", so I leave it out of inflow.
monthly AS (
    SELECT
        loan_id,
        date_trunc('month', trans_date) AS month,
        coalesce(sum(amount) FILTER (WHERE direction = 'Credit' AND operation <> 'Interest credited'), 0) AS inflow,
        coalesce(sum(amount) FILTER (WHERE direction = 'Debit'), 0) AS outflow
    FROM pre_loan_txn
    GROUP BY loan_id, date_trunc('month', trans_date)
),

monthly_stats AS (
    SELECT
        loan_id,
        count(*)                AS months_of_history,
        round(avg(inflow), 2)   AS avg_monthly_inflow,
        round(avg(outflow), 2)  AS avg_monthly_outflow
    FROM monthly
    GROUP BY loan_id
),

-- Were household bills (SIPO) going out of the account before the loan?
-- It's a rough sign that this is the customer's main, day-to-day account.
-- (I also tried a "receives a pension" flag here, but no account with a loan
-- ever received a pension, so it was always false. See 06 for more on that.)
household_bills AS (
    SELECT DISTINCT loan_id
    FROM pre_loan_txn
    WHERE purpose = 'Household bills'
)

SELECT
    -- the loan
    l.loan_id,
    l.account_id,
    l.loan_date,
    l.amount,
    l.duration_months,
    l.monthly_payment,
    l.status_code,
    l.loan_state,
    l.is_default,

    -- the customer
    o.client_id,
    o.gender,
    o.age_at_loan,
    au.users_on_account,
    (au.users_on_account > 1)                                AS has_second_user,
    CASE cb.card_rank WHEN 3 THEN 'gold' WHEN 2 THEN 'classic' WHEN 1 THEN 'junior' ELSE 'none' END
                                                             AS card_before_loan,
    (hb.loan_id IS NOT NULL)                                 AS pays_household_bills,

    -- the account
    a.statement_frequency,
    (l.loan_date - a.opened_date)                            AS account_age_days,

    -- where they live (district of the account)
    dt.district_name,
    dt.region,
    dt.avg_salary                                            AS district_avg_salary,
    dt.unemployment_rate_96                                  AS district_unemployment_96,

    -- behaviour before the loan
    bs.n_transactions,
    ms.months_of_history,
    bs.avg_balance,
    bs.min_balance,
    bs.balance_volatility,
    lb.balance_before_loan,
    rs.min_balance_last_90d,
    rs.avg_balance_last_90d,
    bs.negative_balance_txns,
    bs.penalty_interest_charges,
    (bs.negative_balance_txns > 0)                           AS ever_overdrawn,
    bs.cash_withdrawal_share,
    ms.avg_monthly_inflow,
    ms.avg_monthly_outflow,

    -- affordability: what share of a typical month's income the repayment eats
    round(l.monthly_payment / nullif(ms.avg_monthly_inflow, 0), 3) AS payment_to_income_ratio,
    -- how many monthly payments the average balance could cover
    round(bs.avg_balance / l.monthly_payment, 2)             AS balance_cover_months

FROM clean.loan l
JOIN loan_owner      o  USING (loan_id)
JOIN clean.account   a  ON a.account_id = l.account_id
JOIN clean.district  dt ON dt.district_id = a.district_id
JOIN account_users   au ON au.account_id = l.account_id
JOIN balance_stats   bs USING (loan_id)
JOIN last_balance    lb USING (loan_id)
JOIN monthly_stats   ms USING (loan_id)
LEFT JOIN recent_stats     rs USING (loan_id)
LEFT JOIN card_before_loan cb USING (loan_id)
LEFT JOIN household_bills  hb USING (loan_id);

ALTER TABLE analytics.loan_features ADD PRIMARY KEY (loan_id);

COMMENT ON TABLE analytics.loan_features IS
    'One row per loan. Customer profile plus account behaviour strictly before the loan date (no leakage).';


-- -----------------------------------------------------------------------------
-- Checks
-- -----------------------------------------------------------------------------

-- Every loan should have made it through the joins
SELECT
    (SELECT count(*) FROM clean.loan)             AS loans,
    (SELECT count(*) FROM analytics.loan_features) AS feature_rows,
    (SELECT count(*) FROM analytics.loan_features WHERE min_balance_last_90d IS NULL) AS missing_recent_window;

-- Side-by-side averages for good and bad loans: a first look at what differs
SELECT
    CASE WHEN is_default THEN 'Bad (B/D)' ELSE 'Good (A/C)' END AS loan_outcome,
    count(*)                               AS loans,
    round(avg(amount))                     AS avg_amount,
    round(avg(monthly_payment))            AS avg_monthly_payment,
    round(avg(avg_monthly_inflow))         AS avg_monthly_inflow,
    round(avg(payment_to_income_ratio), 3) AS avg_payment_to_income,
    round(avg(avg_balance))                AS avg_balance,
    round(avg(min_balance))                AS avg_min_balance,
    round(avg(balance_before_loan))        AS avg_balance_before_loan,
    round(100.0 * avg(ever_overdrawn::int), 1)  AS pct_ever_overdrawn,
    round(100.0 * avg(has_second_user::int), 1) AS pct_with_second_user
FROM analytics.loan_features
GROUP BY 1
ORDER BY 1;
