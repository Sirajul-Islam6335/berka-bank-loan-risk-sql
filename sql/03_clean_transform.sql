-- =============================================================================
-- 03_clean_transform.sql
--
-- Builds the clean.* layer: proper data types, English labels, primary and
-- foreign keys, and a couple of derived columns that make analysis easier.
--
-- Every decision here comes from something in 02_data_quality_checks.sql:
--   * YYMMDD text           -> DATE (always 19xx)
--   * birth_number          -> gender + birth_date (women: month + 50)
--   * Czech codes           -> English, using the PKDD'99 documentation
--   * '', ' ' and NULL codes -> NULL
--   * Jesenik's '?' values  -> NULL
--   * trans type 'VYBER'    -> Debit (shown by the balance check)
--   * bank '' / account '0' -> NULL
--   * loan status A/B/C/D   -> loan_state + is_default (B or D = bad loan)
--
-- The script can be re-run safely: it drops and rebuilds everything.
-- =============================================================================

-- Children first so the foreign keys don't get in the way
DROP TABLE IF EXISTS clean.transactions    CASCADE;
DROP TABLE IF EXISTS clean.permanent_order CASCADE;
DROP TABLE IF EXISTS clean.loan            CASCADE;
DROP TABLE IF EXISTS clean.card            CASCADE;
DROP TABLE IF EXISTS clean.disposition     CASCADE;
DROP TABLE IF EXISTS clean.account         CASCADE;
DROP TABLE IF EXISTS clean.client          CASCADE;
DROP TABLE IF EXISTS clean.district        CASCADE;


-- -----------------------------------------------------------------------------
-- district
-- -----------------------------------------------------------------------------
CREATE TABLE clean.district (
    district_id             int           PRIMARY KEY,
    district_name           text          NOT NULL,
    region                  text          NOT NULL,
    inhabitants             int           NOT NULL,
    num_cities              int           NOT NULL,
    urban_ratio_pct         numeric(5,1)  NOT NULL,
    avg_salary              int           NOT NULL,
    unemployment_rate_95    numeric(5,2),             -- NULL for Jesenik
    unemployment_rate_96    numeric(5,2)  NOT NULL,
    entrepreneurs_per_1000  int           NOT NULL,
    crimes_95               int,                      -- NULL for Jesenik
    crimes_96               int           NOT NULL
);

INSERT INTO clean.district
SELECT
    a1::int,
    trim(a2),
    trim(a3),
    a4::int,
    a9::int,
    a10::numeric,
    a11::int,
    nullif(a12, '?')::numeric,
    a13::numeric,
    a14::int,
    nullif(a15, '?')::int,
    a16::int
FROM raw.district;


-- -----------------------------------------------------------------------------
-- client
-- birth_number is YYMMDD, except that women have 50 added to the month,
-- e.g. 706213 = a woman born 13 Dec 1970.
-- -----------------------------------------------------------------------------
CREATE TABLE clean.client (
    client_id    int      PRIMARY KEY,
    district_id  int      NOT NULL REFERENCES clean.district,
    gender       char(1)  NOT NULL CHECK (gender IN ('M', 'F')),
    birth_date   date     NOT NULL
);

INSERT INTO clean.client
SELECT
    client_id::int,
    district_id::int,
    CASE WHEN substr(birth_number, 3, 2)::int > 50 THEN 'F' ELSE 'M' END,
    make_date(
        1900 + substr(birth_number, 1, 2)::int,
        substr(birth_number, 3, 2)::int % 50,
        substr(birth_number, 5, 2)::int
    )
FROM raw.client;


-- -----------------------------------------------------------------------------
-- account
-- -----------------------------------------------------------------------------
CREATE TABLE clean.account (
    account_id           int   PRIMARY KEY,
    district_id          int   NOT NULL REFERENCES clean.district,
    statement_frequency  text  NOT NULL,
    opened_date          date  NOT NULL
);

INSERT INTO clean.account
SELECT
    account_id::int,
    district_id::int,
    CASE frequency
        WHEN 'POPLATEK MESICNE'   THEN 'Monthly'
        WHEN 'POPLATEK TYDNE'     THEN 'Weekly'
        WHEN 'POPLATEK PO OBRATU' THEN 'After each transaction'
    END,
    to_date('19' || date, 'YYYYMMDD')
FROM raw.account;


-- -----------------------------------------------------------------------------
-- disposition: which client can use which account, and in what role
-- -----------------------------------------------------------------------------
CREATE TABLE clean.disposition (
    disp_id     int   PRIMARY KEY,
    client_id   int   NOT NULL REFERENCES clean.client,
    account_id  int   NOT NULL REFERENCES clean.account,
    role        text  NOT NULL CHECK (role IN ('Owner', 'Authorised user'))
);

INSERT INTO clean.disposition
SELECT
    disp_id::int,
    client_id::int,
    account_id::int,
    CASE type WHEN 'OWNER' THEN 'Owner' ELSE 'Authorised user' END
FROM raw.disp;


-- -----------------------------------------------------------------------------
-- card (issued looks like '931107 00:00:00', so I only keep the date part)
-- -----------------------------------------------------------------------------
CREATE TABLE clean.card (
    card_id      int   PRIMARY KEY,
    disp_id      int   NOT NULL REFERENCES clean.disposition,
    card_type    text  NOT NULL CHECK (card_type IN ('junior', 'classic', 'gold')),
    issued_date  date  NOT NULL
);

INSERT INTO clean.card
SELECT
    card_id::int,
    disp_id::int,
    type,
    to_date('19' || left(issued, 6), 'YYYYMMDD')
FROM raw.card;


-- -----------------------------------------------------------------------------
-- loan
--   A = finished, repaid           B = finished, NOT repaid
--   C = running, up to date        D = running, in arrears
-- B and D together are the "bad" loans I'm trying to explain.
-- -----------------------------------------------------------------------------
CREATE TABLE clean.loan (
    loan_id          int            PRIMARY KEY,
    account_id       int            NOT NULL UNIQUE REFERENCES clean.account,
    loan_date        date           NOT NULL,
    amount           numeric(12,2)  NOT NULL,
    duration_months  int            NOT NULL,
    monthly_payment  numeric(12,2)  NOT NULL,
    status_code      char(1)        NOT NULL CHECK (status_code IN ('A', 'B', 'C', 'D')),
    status_desc      text           NOT NULL,
    loan_state       text           NOT NULL,
    is_default       boolean        NOT NULL
);

INSERT INTO clean.loan
SELECT
    loan_id::int,
    account_id::int,
    to_date('19' || date, 'YYYYMMDD'),
    amount::numeric,
    duration::int,
    payments::numeric,
    status,
    CASE status
        WHEN 'A' THEN 'Finished - repaid'
        WHEN 'B' THEN 'Finished - not repaid'
        WHEN 'C' THEN 'Running - up to date'
        WHEN 'D' THEN 'Running - in arrears'
    END,
    CASE WHEN status IN ('A', 'B') THEN 'Finished' ELSE 'Running' END,
    status IN ('B', 'D')
FROM raw.loan;


-- -----------------------------------------------------------------------------
-- permanent_order (standing orders set up on the account)
-- -----------------------------------------------------------------------------
CREATE TABLE clean.permanent_order (
    order_id           int            PRIMARY KEY,
    account_id         int            NOT NULL REFERENCES clean.account,
    recipient_bank     text           NOT NULL,
    recipient_account  text           NOT NULL,
    amount             numeric(12,2)  NOT NULL,
    purpose            text
);

INSERT INTO clean.permanent_order
SELECT
    order_id::int,
    account_id::int,
    bank_to,
    account_to,
    amount::numeric,
    CASE nullif(trim(k_symbol), '')
        WHEN 'POJISTNE' THEN 'Insurance'
        WHEN 'SIPO'     THEN 'Household bills'
        WHEN 'LEASING'  THEN 'Leasing'
        WHEN 'UVER'     THEN 'Loan repayment'
    END
FROM raw.orders;


-- -----------------------------------------------------------------------------
-- transactions
-- signed_amount is +credit / -debit. It's not strictly needed, but it turns
-- most cash-flow questions into a simple SUM().
-- -----------------------------------------------------------------------------
CREATE TABLE clean.transactions (
    trans_id         int            PRIMARY KEY,
    account_id       int            NOT NULL REFERENCES clean.account,
    trans_date       date           NOT NULL,
    direction        text           NOT NULL CHECK (direction IN ('Credit', 'Debit')),
    operation        text           NOT NULL,
    amount           numeric(12,2)  NOT NULL CHECK (amount >= 0),
    signed_amount    numeric(12,2)  NOT NULL,
    balance          numeric(12,2)  NOT NULL,
    purpose          text,
    partner_bank     text,
    partner_account  text
);

INSERT INTO clean.transactions
SELECT
    trans_id::int,
    account_id::int,
    to_date('19' || date, 'YYYYMMDD'),
    CASE WHEN type = 'PRIJEM' THEN 'Credit' ELSE 'Debit' END,
    CASE operation
        WHEN 'VKLAD'          THEN 'Cash deposit'
        WHEN 'PREVOD Z UCTU'  THEN 'Transfer in'
        WHEN 'VYBER'          THEN 'Cash withdrawal'
        WHEN 'VYBER KARTOU'   THEN 'Card withdrawal'
        WHEN 'PREVOD NA UCET' THEN 'Transfer out'
        WHEN ''               THEN 'Interest credited'   -- all blank operations are UROK
    END,
    amount::numeric,
    CASE WHEN type = 'PRIJEM' THEN amount::numeric ELSE -amount::numeric END,
    balance::numeric,
    CASE nullif(trim(k_symbol), '')
        WHEN 'POJISTNE'    THEN 'Insurance'
        WHEN 'SLUZBY'      THEN 'Statement fee'
        WHEN 'UROK'        THEN 'Interest credited'
        WHEN 'SANKC. UROK' THEN 'Penalty interest (overdrawn)'
        WHEN 'SIPO'        THEN 'Household bills'
        WHEN 'DUCHOD'      THEN 'Pension'
        WHEN 'UVER'        THEN 'Loan repayment'
    END,
    nullif(bank, ''),
    CASE WHEN bank = '' AND account = '0' THEN NULL ELSE account END
FROM raw.trans;

-- Almost every query later filters by account and date, so index that pair
CREATE INDEX ix_transactions_account_date ON clean.transactions (account_id, trans_date);
CREATE INDEX ix_disposition_account       ON clean.disposition (account_id);

ANALYZE clean.district, clean.client, clean.account, clean.disposition,
        clean.card, clean.loan, clean.permanent_order, clean.transactions;


-- -----------------------------------------------------------------------------
-- Post-load checks
-- -----------------------------------------------------------------------------

-- 1. Nothing lost on the way: raw and clean row counts must match
SELECT 'district' AS table_name, (SELECT count(*) FROM raw.district) AS raw_rows, (SELECT count(*) FROM clean.district) AS clean_rows
UNION ALL SELECT 'client',  (SELECT count(*) FROM raw.client),  (SELECT count(*) FROM clean.client)
UNION ALL SELECT 'account', (SELECT count(*) FROM raw.account), (SELECT count(*) FROM clean.account)
UNION ALL SELECT 'disp',    (SELECT count(*) FROM raw.disp),    (SELECT count(*) FROM clean.disposition)
UNION ALL SELECT 'card',    (SELECT count(*) FROM raw.card),    (SELECT count(*) FROM clean.card)
UNION ALL SELECT 'loan',    (SELECT count(*) FROM raw.loan),    (SELECT count(*) FROM clean.loan)
UNION ALL SELECT 'orders',  (SELECT count(*) FROM raw.orders),  (SELECT count(*) FROM clean.permanent_order)
UNION ALL SELECT 'trans',   (SELECT count(*) FROM raw.trans),   (SELECT count(*) FROM clean.transactions);

-- 2. No code fell through a CASE without being translated
SELECT
    (SELECT count(*) FROM clean.transactions WHERE operation IS NULL)           AS untranslated_operations,
    (SELECT count(*) FROM clean.account      WHERE statement_frequency IS NULL) AS untranslated_frequencies;

-- 3. Gender decode looks sensible (roughly 50/50, plausible birth years)
SELECT gender, count(*) AS clients, min(birth_date) AS oldest, max(birth_date) AS youngest
FROM clean.client
GROUP BY gender;
