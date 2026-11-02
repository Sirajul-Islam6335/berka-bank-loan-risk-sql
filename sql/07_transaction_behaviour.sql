-- =============================================================================
-- 07_transaction_behaviour.sql
--
-- What does money moving through the bank look like, and how do accounts
-- with bad loans behave differently from everyone else?
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Bank-wide monthly activity, with month-on-month growth
-- -----------------------------------------------------------------------------
WITH monthly AS (
    SELECT
        date_trunc('month', trans_date)::date             AS month,
        count(DISTINCT account_id)                         AS active_accounts,
        count(*)                                           AS transactions,
        sum(amount) FILTER (WHERE direction = 'Credit')    AS money_in,
        sum(amount) FILTER (WHERE direction = 'Debit')     AS money_out
    FROM clean.transactions
    GROUP BY 1
)
SELECT
    month,
    active_accounts,
    transactions,
    round(money_in)                                        AS money_in,
    round(money_out)                                       AS money_out,
    round(money_in - money_out)                            AS net_flow,
    round(100.0 * (active_accounts - lag(active_accounts) OVER (ORDER BY month))
          / lag(active_accounts) OVER (ORDER BY month), 1) AS active_accounts_mom_pct
FROM monthly
ORDER BY month;
-- The bank grows fast: 96 active accounts in January 1993, about 4,480 by
-- the start of 1998. Then it goes flat, because no new accounts were opened
-- after December 1997. The big negative net flows in January and June 1998
-- are worth a closer look some day (seasonal? a data quirk?), but they
-- don't affect the loan analysis.


-- -----------------------------------------------------------------------------
-- 2. What are people actually doing? Transaction mix by operation
-- -----------------------------------------------------------------------------
SELECT
    direction,
    operation,
    count(*)                                              AS transactions,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)    AS pct_of_all_txns,
    round(avg(amount))                                    AS avg_amount
FROM clean.transactions
GROUP BY direction, operation
ORDER BY transactions DESC;
-- Cash withdrawals are 41% of everything, a reminder that this is a
-- 1990s, mostly-cash economy. Card withdrawals are under 1%.


-- -----------------------------------------------------------------------------
-- 3. Overdrafts and penalty interest over time
-- -----------------------------------------------------------------------------
SELECT
    extract(year FROM trans_date)::int                                   AS year,
    count(DISTINCT account_id) FILTER (WHERE balance < 0)                AS accounts_overdrawn,
    count(*) FILTER (WHERE balance < 0)                                  AS overdrawn_txns,
    count(*) FILTER (WHERE purpose = 'Penalty interest (overdrawn)')     AS penalty_interest_charges,
    round(sum(amount) FILTER (WHERE purpose = 'Penalty interest (overdrawn)')) AS penalty_interest_czk
FROM clean.transactions
GROUP BY 1
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 4. Who gets overdrawn? Overdrawn accounts split by loan status
-- -----------------------------------------------------------------------------
WITH overdrawn AS (
    SELECT DISTINCT account_id FROM clean.transactions WHERE balance < 0
)
SELECT
    coalesce(l.status_desc, 'No loan')                      AS loan_status,
    count(*)                                                AS accounts,
    count(o.account_id)                                     AS ever_overdrawn,
    round(100.0 * count(o.account_id) / count(*), 1)        AS pct_ever_overdrawn
FROM clean.account a
LEFT JOIN clean.loan l USING (account_id)
LEFT JOIN overdrawn o  USING (account_id)
GROUP BY 1
ORDER BY pct_ever_overdrawn DESC;
-- This is the clearest split in the whole dataset. Every one of the 76
-- accounts with a bad loan was overdrawn at some point, and not one of the
-- 606 accounts with a good loan ever was. (Only 5.6% of accounts without a
-- loan were.) Part of that is the default itself pushing the balance below
-- zero, which is why 04 only looks at overdrafts BEFORE the loan.
--
-- Penalty interest in 1998 (above) is 4x the 1997 figure, which lines up
-- with the arrears building on running loans. See 09.


-- -----------------------------------------------------------------------------
-- 5. Balance path around the loan date
--    Average month-end balance for good vs bad loans, from 6 months before
--    the loan to 12 months after. Month 0 is the month the loan was paid out.
--    (This uses data after the loan too, so it's descriptive only: it shows
--    what happens, and it isn't something you could use to approve a loan.)
-- -----------------------------------------------------------------------------
WITH month_end AS (
    -- last balance in each calendar month for each account
    SELECT DISTINCT ON (account_id, date_trunc('month', trans_date))
        account_id,
        date_trunc('month', trans_date)::date AS month,
        balance
    FROM clean.transactions
    ORDER BY account_id, date_trunc('month', trans_date), trans_date DESC, trans_id DESC
),
relative AS (
    SELECT
        l.is_default,
        (extract(year FROM age(m.month, date_trunc('month', l.loan_date))) * 12
         + extract(month FROM age(m.month, date_trunc('month', l.loan_date))))::int AS months_from_loan,
        m.balance
    FROM clean.loan l
    JOIN month_end m ON m.account_id = l.account_id
)
SELECT
    months_from_loan,
    round(avg(balance) FILTER (WHERE NOT is_default)) AS avg_balance_good_loans,
    round(avg(balance) FILTER (WHERE is_default))     AS avg_balance_bad_loans,
    count(*) FILTER (WHERE is_default)                AS bad_loans_observed
FROM relative
WHERE months_from_loan BETWEEN -6 AND 12
GROUP BY months_from_loan
ORDER BY months_from_loan;
-- The gap is already there six months before the loan (about 41k vs 31k
-- CZK) and gets wider in the months just before it: by month -1 good
-- borrowers hold about 42.7k and the ones who go bad about 26.5k. After the
-- loan, the bad group stays stuck in the mid-20k range. So the warning sign
-- is visible on the day of the application.


-- -----------------------------------------------------------------------------
-- 6. Typical monthly income and spending across all accounts
--    (median, so a few very large accounts don't skew it)
-- -----------------------------------------------------------------------------
WITH acct_month AS (
    SELECT
        account_id,
        date_trunc('month', trans_date) AS month,
        sum(amount) FILTER (WHERE direction = 'Credit' AND operation <> 'Interest credited') AS inflow,
        sum(amount) FILTER (WHERE direction = 'Debit')                                     AS outflow
    FROM clean.transactions
    GROUP BY 1, 2
)
SELECT
    round(percentile_cont(0.25) WITHIN GROUP (ORDER BY inflow)::numeric)  AS inflow_p25,
    round(percentile_cont(0.50) WITHIN GROUP (ORDER BY inflow)::numeric)  AS inflow_median,
    round(percentile_cont(0.75) WITHIN GROUP (ORDER BY inflow)::numeric)  AS inflow_p75,
    round(percentile_cont(0.50) WITHIN GROUP (ORDER BY outflow)::numeric) AS outflow_median
FROM acct_month;
