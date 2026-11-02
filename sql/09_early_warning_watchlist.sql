-- =============================================================================
-- 09_early_warning_watchlist.sql
--
-- 08 was about approving loans. This one is about loans that are already
-- out: of the 403 running loans that are currently up to date (status C),
-- which ones are starting to look like the 45 that have already fallen
-- into arrears (status D)?
--
-- "Today" is 31 Dec 1998, the last day in the data, and I look at the last
-- six months (1 Jul - 31 Dec 1998).
--
-- Signals I tested:
--   1. Lowest balance in the last 6 months fell below one monthly repayment
--   2. Penalty interest charged in the last 6 months (i.e. overdrawn)
--   3. Fewer loan repayments than expected in the last 6 months
--   4. Income down more than 20% vs the previous 6 months
--
-- I dropped number 4. It flagged 14% of the healthy C loans and only 20% of
-- the D loans, so it barely tells the two groups apart. The other three are
-- much sharper (see check 1 below).
-- =============================================================================

DROP TABLE IF EXISTS analytics.early_warning CASCADE;

CREATE TABLE analytics.early_warning AS
WITH params AS (
    SELECT date '1998-12-31' AS as_of,
           date '1998-07-01' AS window_start
),
running AS (
    SELECT l.*
    FROM clean.loan l
    WHERE l.loan_state = 'Running'
),
recent AS (
    SELECT
        r.loan_id,
        min(t.balance)                                                       AS min_balance_6m,
        count(*) FILTER (WHERE t.purpose = 'Penalty interest (overdrawn)')   AS penalty_charges_6m,
        count(*) FILTER (WHERE t.purpose = 'Loan repayment')                 AS repayments_6m
    FROM running r
    CROSS JOIN params p
    -- For loans paid out during the window, only count what happened after
    -- the loan. Otherwise a low balance from before the money arrived
    -- would count against them.
    JOIN clean.transactions t
      ON t.account_id = r.account_id
     AND t.trans_date BETWEEN greatest(p.window_start, r.loan_date) AND p.as_of
    GROUP BY r.loan_id
),
latest_balance AS (
    SELECT DISTINCT ON (r.loan_id)
        r.loan_id,
        t.balance AS balance_at_31_dec_1998
    FROM running r
    JOIN clean.transactions t ON t.account_id = r.account_id
    ORDER BY r.loan_id, t.trans_date DESC, t.trans_id DESC
)
SELECT
    r.loan_id,
    r.account_id,
    d.client_id,
    r.status_code,
    r.loan_date,
    r.amount,
    r.duration_months,
    r.monthly_payment,

    -- rough outstanding amount: payments still to come under the schedule
    greatest(
        r.duration_months
        - (extract(year FROM age(p.as_of, r.loan_date)) * 12
           + extract(month FROM age(p.as_of, r.loan_date)))::int,
        0) * r.monthly_payment                                         AS est_remaining_czk,

    lb.balance_at_31_dec_1998,
    rc.min_balance_6m,
    rc.penalty_charges_6m,
    rc.repayments_6m,

    -- signals
    (rc.min_balance_6m < r.monthly_payment)                            AS sig_balance_below_one_payment,
    (rc.penalty_charges_6m > 0)                                        AS sig_penalty_interest,
    -- only judge missed payments for loans that existed for the whole window
    (r.loan_date < date '1998-06-01' AND rc.repayments_6m < 6)         AS sig_missed_repayments
FROM running r
CROSS JOIN params p
JOIN recent rc          USING (loan_id)
JOIN latest_balance lb  USING (loan_id)
JOIN clean.disposition d ON d.account_id = r.account_id AND d.role = 'Owner';

ALTER TABLE analytics.early_warning
    ADD COLUMN signal_count int;

UPDATE analytics.early_warning
SET signal_count = sig_balance_below_one_payment::int
                 + sig_penalty_interest::int
                 + sig_missed_repayments::int;

ALTER TABLE analytics.early_warning ADD PRIMARY KEY (loan_id);


-- -----------------------------------------------------------------------------
-- 1. Do the signals actually work? Compare how often each fires for loans
--    already in arrears (D) vs loans still up to date (C).
-- -----------------------------------------------------------------------------
SELECT
    status_code,
    count(*)                                                                    AS loans,
    round(100.0 * avg(sig_balance_below_one_payment::int), 1)                   AS pct_balance_below_payment,
    round(100.0 * avg(sig_penalty_interest::int), 1)                            AS pct_penalty_interest,
    round(100.0 * avg(sig_missed_repayments::int), 1)                           AS pct_missed_repayments,
    round(100.0 * avg((signal_count > 0)::int), 1)                              AS pct_any_signal
FROM analytics.early_warning
GROUP BY status_code
ORDER BY status_code;
-- Each signal fires for roughly a third to a half of D loans, but only for
-- 0.2-2.5% of C loans. 60% of D loans show at least one, against 3% of C
-- loans. So a C loan with a signal looks a lot more like a D loan than a
-- normal C loan.


-- -----------------------------------------------------------------------------
-- 2. The watchlist: currently up-to-date loans showing at least one signal,
--    riskiest first. This is the list I'd hand to a collections or
--    relationship team.
-- -----------------------------------------------------------------------------
SELECT
    loan_id,
    account_id,
    client_id,
    loan_date,
    amount,
    monthly_payment,
    est_remaining_czk,
    round(min_balance_6m)          AS min_balance_6m,
    round(balance_at_31_dec_1998)  AS balance_now,
    penalty_charges_6m,
    repayments_6m,
    signal_count,
    concat_ws(', ',
        CASE WHEN sig_balance_below_one_payment THEN 'balance below one payment' END,
        CASE WHEN sig_penalty_interest          THEN 'penalty interest' END,
        CASE WHEN sig_missed_repayments         THEN 'missed repayments' END
    )                              AS reasons
FROM analytics.early_warning
WHERE status_code = 'C'
  AND signal_count > 0
ORDER BY signal_count DESC, est_remaining_czk DESC;


-- -----------------------------------------------------------------------------
-- 3. Size of the problem: how much money is sitting on the watchlist?
-- -----------------------------------------------------------------------------
SELECT
    count(*)                                                AS watchlist_loans,
    sum(est_remaining_czk)                                  AS watchlist_remaining_czk,
    (SELECT sum(est_remaining_czk) FROM analytics.early_warning WHERE status_code = 'C')
                                                            AS all_performing_remaining_czk,
    round(100.0 * sum(est_remaining_czk)
          / (SELECT sum(est_remaining_czk) FROM analytics.early_warning WHERE status_code = 'C'), 1)
                                                            AS watchlist_pct_of_performing_book
FROM analytics.early_warning
WHERE status_code = 'C' AND signal_count > 0;
-- 12 loans with about 1.9m CZK still to be repaid, 4.7% of the performing
-- book. That's a list small enough for a team to phone every customer on it.
