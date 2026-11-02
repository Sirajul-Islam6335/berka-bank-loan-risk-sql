-- -----------------------------------------------------------------------------
-- 1. Duplicate primary keys
-- -----------------------------------------------------------------------------
SELECT 'account' AS table_name, count(*) - count(DISTINCT account_id) AS duplicate_keys FROM raw.account
UNION ALL SELECT 'client', count(*) - count(DISTINCT client_id) FROM raw.client
UNION ALL SELECT 'disp',   count(*) - count(DISTINCT disp_id)   FROM raw.disp
UNION ALL SELECT 'card',   count(*) - count(DISTINCT card_id)   FROM raw.card
UNION ALL SELECT 'loan',   count(*) - count(DISTINCT loan_id)   FROM raw.loan
UNION ALL SELECT 'orders', count(*) - count(DISTINCT order_id)  FROM raw.orders
UNION ALL SELECT 'trans',  count(*) - count(DISTINCT trans_id)  FROM raw.trans;
-- Found: 0 duplicates in every table. Safe to use these as primary keys.


-- -----------------------------------------------------------------------------
-- 2. Orphan rows (a child row pointing at a parent that doesn't exist)
-- -----------------------------------------------------------------------------
SELECT 'trans -> account' AS relationship, count(*) AS orphan_rows
FROM raw.trans t LEFT JOIN raw.account a USING (account_id) WHERE a.account_id IS NULL
UNION ALL
SELECT 'loan -> account', count(*)
FROM raw.loan l LEFT JOIN raw.account a USING (account_id) WHERE a.account_id IS NULL
UNION ALL
SELECT 'orders -> account', count(*)
FROM raw.orders o LEFT JOIN raw.account a USING (account_id) WHERE a.account_id IS NULL
UNION ALL
SELECT 'disp -> client', count(*)
FROM raw.disp d LEFT JOIN raw.client c USING (client_id) WHERE c.client_id IS NULL
UNION ALL
SELECT 'disp -> account', count(*)
FROM raw.disp d LEFT JOIN raw.account a USING (account_id) WHERE a.account_id IS NULL
UNION ALL
SELECT 'card -> disp', count(*)
FROM raw.card c LEFT JOIN raw.disp d USING (disp_id) WHERE d.disp_id IS NULL
UNION ALL
SELECT 'account -> district', count(*)
FROM raw.account a LEFT JOIN raw.district d ON d.a1 = a.district_id WHERE d.a1 IS NULL
UNION ALL
SELECT 'client -> district', count(*)
FROM raw.client c LEFT JOIN raw.district d ON d.a1 = c.district_id WHERE d.a1 IS NULL;
-- Found: 0 orphans everywhere, so foreign keys can be added in the clean layer.


-- -----------------------------------------------------------------------------
-- 3. Business rules I'm relying on later
--    - each account has at most one loan (so loan-level = account-level)
--    - each account has exactly one owner (so I can attach one person to a loan)
-- -----------------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM (SELECT account_id FROM raw.loan GROUP BY account_id HAVING count(*) > 1) x)
        AS accounts_with_more_than_one_loan,
    (SELECT count(*) FROM (SELECT account_id FROM raw.disp WHERE type = 'OWNER'
                           GROUP BY account_id HAVING count(*) <> 1) x)
        AS accounts_without_exactly_one_owner;
-- Found: 0 and 0. Both rules hold.


-- -----------------------------------------------------------------------------
-- 4. Values that won't convert to numbers in the district table
-- -----------------------------------------------------------------------------
SELECT a1 AS district_id, a2 AS district_name, a12 AS unemployment_95, a15 AS crimes_95
FROM raw.district
WHERE a12 !~ '^[0-9.]+$' OR a15 !~ '^[0-9]+$';
-- Found: one district (Jesenik) has '?' for both 1995 figures. I turn those
-- into NULL and use the complete 1996 columns in the analysis instead.


-- -----------------------------------------------------------------------------
-- 5. Every code value in the categorical columns (they're all in Czech)
-- -----------------------------------------------------------------------------
SELECT 'trans.type' AS field, type AS code, count(*) AS n FROM raw.trans GROUP BY type
UNION ALL SELECT 'trans.operation', '[' || operation || ']', count(*) FROM raw.trans GROUP BY operation
UNION ALL SELECT 'trans.k_symbol', coalesce('[' || k_symbol || ']', 'NULL'), count(*) FROM raw.trans GROUP BY k_symbol
UNION ALL SELECT 'orders.k_symbol', '[' || k_symbol || ']', count(*) FROM raw.orders GROUP BY k_symbol
UNION ALL SELECT 'account.frequency', frequency, count(*) FROM raw.account GROUP BY frequency
UNION ALL SELECT 'loan.status', status, count(*) FROM raw.loan GROUP BY status
UNION ALL SELECT 'card.type', type, count(*) FROM raw.card GROUP BY type
UNION ALL SELECT 'disp.type', type, count(*) FROM raw.disp GROUP BY type
ORDER BY field, n DESC;
-- Found a few things the documentation doesn't mention:
--   * trans.type has a third value, 'VYBER' (16,666 rows), next to the
--     documented PRIJEM (credit) and VYDAJ (debit). Check 6 shows it's a debit.
--   * trans.operation is an empty string on 183,114 rows (see check 7)
--   * "missing" k_symbol shows up three ways: '' (481,871), ' ' (53,433) and
--     NULL (10). All three mean the same thing, so they all become NULL.
--   * orders.k_symbol also has 1,379 rows that are a single space.


-- -----------------------------------------------------------------------------
-- 6. Is the undocumented 'VYBER' type a debit or a credit?
--    If a transaction is the only one on its account that day, then
--    previous balance -/+ amount should equal the new balance. I count
--    which formula fits for each type.
-- -----------------------------------------------------------------------------
WITH t AS (
    SELECT
        type,
        amount::numeric  AS amount,
        balance::numeric AS balance,
        lag(balance::numeric) OVER (PARTITION BY account_id ORDER BY date, trans_id::int) AS prev_balance,
        count(*) OVER (PARTITION BY account_id, date) AS txns_that_day
    FROM raw.trans
)
SELECT
    type,
    count(*)                                                         AS rows_checked,
    count(*) FILTER (WHERE abs(prev_balance - amount - balance) < 0.01) AS fits_as_debit,
    count(*) FILTER (WHERE abs(prev_balance + amount - balance) < 0.01) AS fits_as_credit
FROM t
WHERE txns_that_day = 1 AND prev_balance IS NOT NULL
GROUP BY type;
-- Found: VYBER fits as a debit 10,697 times and as a credit 0 times, the
-- same pattern as VYDAJ. So it's treated as a debit.


-- -----------------------------------------------------------------------------
-- 7. What are the rows with a blank operation?
-- -----------------------------------------------------------------------------
SELECT type, k_symbol, count(*) AS n
FROM raw.trans
WHERE operation = ''
GROUP BY type, k_symbol;
-- Found: all 183,114 are PRIJEM + UROK, i.e. the bank crediting interest.
-- I label the operation 'Interest credited' instead of leaving it blank.


-- -----------------------------------------------------------------------------
-- 8. Partner bank / account fields
-- -----------------------------------------------------------------------------
SELECT
    count(*) FILTER (WHERE bank IS NULL)                  AS bank_null,
    count(*) FILTER (WHERE bank = '' AND account = '0')   AS bank_blank_account_zero,
    count(*) FILTER (WHERE bank <> '')                    AS bank_present
FROM raw.trans;
-- Found: 760,931 NULL, plus 21,881 rows with bank '' and account '0'. Both
-- mean "no counterparty", so both become NULL.


-- -----------------------------------------------------------------------------
-- 9. Amounts and balances
-- -----------------------------------------------------------------------------
SELECT
    min(amount::numeric)                              AS min_amount,
    max(amount::numeric)                              AS max_amount,
    count(*) FILTER (WHERE amount::numeric = 0)       AS zero_amount_rows,
    min(balance::numeric)                             AS min_balance,
    count(*) FILTER (WHERE balance::numeric < 0)      AS negative_balance_rows
FROM raw.trans;
-- Found: amounts run 0 to 87,400 CZK (14 zero-value rows, which I keep).
-- 2,999 transactions left the account overdrawn, lowest -41,125.70.
-- Negative balances turn out to be one of the strongest risk signals later on.


-- -----------------------------------------------------------------------------
-- 10. Loan arithmetic: does amount = duration x monthly payment?
-- -----------------------------------------------------------------------------
SELECT
    count(*) AS loans,
    count(*) FILTER (WHERE abs(amount::numeric - duration::int * payments::numeric) < 1)
        AS amount_matches_duration_x_payment
FROM raw.loan;
-- Found: 682 / 682. Every loan is exactly duration x payment, so the amount
-- includes the full repayment schedule and no interest shows up separately.


-- -----------------------------------------------------------------------------
-- 11. Date coverage (still YYMMDD text at this point)
-- -----------------------------------------------------------------------------
SELECT 'trans' AS table_name, min(date) AS first_yymmdd, max(date) AS last_yymmdd FROM raw.trans
UNION ALL SELECT 'account', min(date), max(date) FROM raw.account
UNION ALL SELECT 'loan',    min(date), max(date) FROM raw.loan;
-- Found: everything falls between 1993-01-01 and 1998-12-31, so the century
-- is always 19xx.


-- -----------------------------------------------------------------------------
-- 12. birth_number encodes gender: women have 50 added to the month.
--     Check that the months fall in 01-12 or 51-62 and nowhere else.
-- -----------------------------------------------------------------------------
SELECT
    count(*) FILTER (WHERE substr(birth_number, 3, 2)::int BETWEEN 1 AND 12)  AS male_pattern,
    count(*) FILTER (WHERE substr(birth_number, 3, 2)::int BETWEEN 51 AND 62) AS female_pattern,
    count(*) FILTER (WHERE substr(birth_number, 3, 2)::int NOT BETWEEN 1 AND 12
                       AND substr(birth_number, 3, 2)::int NOT BETWEEN 51 AND 62) AS invalid
FROM raw.client;
-- Found: 2,724 male, 2,645 female, 0 invalid.
