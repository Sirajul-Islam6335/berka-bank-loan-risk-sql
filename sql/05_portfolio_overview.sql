-- =============================================================================
-- 05_portfolio_overview.sql
--
-- The "state of the loan book" view, the kind of numbers someone would want
-- on the first slide before getting into why loans go bad.
--
-- A "bad" loan in this project is status B (finished, not repaid) or D
-- (running, in arrears). That's the is_default column in clean.loan.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Headline numbers
-- -----------------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM clean.client)                         AS clients,
    (SELECT count(*) FROM clean.account)                        AS accounts,
    count(*)                                                    AS loans,
    round(100.0 * count(*) / (SELECT count(*) FROM clean.account), 1) AS pct_accounts_with_loan,
    sum(amount)                                                 AS total_lent_czk,
    round(avg(amount))                                          AS avg_loan_czk,
    count(*) FILTER (WHERE is_default)                          AS bad_loans,
    round(100.0 * avg(is_default::int), 1)                      AS bad_loan_rate_pct,
    round(100.0 * sum(amount) FILTER (WHERE is_default) / sum(amount), 1) AS bad_loan_share_of_value_pct
FROM clean.loan;
-- 682 loans on 4,500 accounts (15.2%). 76 are bad: 11.1% by count but 15.1%
-- by value, so the bad loans tend to be the bigger ones.


-- -----------------------------------------------------------------------------
-- 2. Loans by status
-- -----------------------------------------------------------------------------
SELECT
    status_code,
    status_desc,
    count(*)                                              AS loans,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)    AS pct_of_loans,
    sum(amount)                                           AS total_amount,
    round(100.0 * sum(amount) / sum(sum(amount)) OVER (), 1) AS pct_of_value,
    round(avg(amount))                                    AS avg_amount
FROM clean.loan
GROUP BY status_code, status_desc
ORDER BY status_code;


-- -----------------------------------------------------------------------------
-- 3. Bad loan rate: finished vs running loans
--    Finished loans have had their whole life to go wrong; running ones
--    haven't yet, so I'd expect the finished rate to be higher.
-- -----------------------------------------------------------------------------
SELECT
    loan_state,
    count(*)                                 AS loans,
    count(*) FILTER (WHERE is_default)       AS bad_loans,
    round(100.0 * avg(is_default::int), 1)   AS bad_loan_rate_pct
FROM clean.loan
GROUP BY loan_state;


-- -----------------------------------------------------------------------------
-- 4. Lending by year, with a running total of the loan book
-- -----------------------------------------------------------------------------
WITH by_year AS (
    SELECT
        extract(year FROM loan_date)::int       AS loan_year,
        count(*)                                AS loans_issued,
        sum(amount)                             AS amount_issued,
        round(100.0 * avg(is_default::int), 1)  AS bad_loan_rate_pct
    FROM clean.loan
    GROUP BY 1
)
SELECT
    loan_year,
    loans_issued,
    amount_issued,
    sum(amount_issued) OVER (ORDER BY loan_year) AS cumulative_amount_issued,
    bad_loan_rate_pct
FROM by_year
ORDER BY loan_year;
-- Careful reading the 1998 rate (2.5%): those loans are only months old and
-- haven't had time to go bad yet. 1994-1997 sit very steadily at 13-14%.


-- -----------------------------------------------------------------------------
-- 5. Loan size bands (quartiles of the amount)
-- -----------------------------------------------------------------------------
WITH banded AS (
    SELECT *, ntile(4) OVER (ORDER BY amount) AS amount_quartile
    FROM clean.loan
)
SELECT
    amount_quartile,
    min(amount)                              AS from_czk,
    max(amount)                              AS to_czk,
    count(*)                                 AS loans,
    round(100.0 * avg(is_default::int), 1)   AS bad_loan_rate_pct
FROM banded
GROUP BY amount_quartile
ORDER BY amount_quartile;
-- The top quarter (over ~212k CZK) goes bad 20% of the time, against
-- 7.6% for the smallest half.


-- -----------------------------------------------------------------------------
-- 6. Loan term
-- -----------------------------------------------------------------------------
SELECT
    duration_months,
    count(*)                                 AS loans,
    round(avg(amount))                       AS avg_amount,
    round(avg(monthly_payment))              AS avg_monthly_payment,
    round(100.0 * avg(is_default::int), 1)   AS bad_loan_rate_pct
FROM clean.loan
GROUP BY duration_months
ORDER BY duration_months;
-- 12-month loans are a bit safer (8.4%); beyond that the term makes little
-- difference (11.5-12.3%).
