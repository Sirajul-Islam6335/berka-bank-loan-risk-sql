-- ---------------------------------------------------------------------------
-- district: demographics for the 77 Czech districts. The columns are just
-- called A1..A16 in the file; I rename them properly in the clean layer.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.district;
CREATE TABLE raw.district (
    a1 text, a2 text, a3 text, a4 text, a5 text, a6 text, a7 text, a8 text,
    a9 text, a10 text, a11 text, a12 text, a13 text, a14 text, a15 text, a16 text
);
COPY raw.district FROM '/data/raw/district.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.account;
CREATE TABLE raw.account (
    account_id text, district_id text, frequency text, date text
);
COPY raw.account FROM '/data/raw/account.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.client;
CREATE TABLE raw.client (
    client_id text, birth_number text, district_id text
);
COPY raw.client FROM '/data/raw/client.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
-- disp links clients to accounts (owner or authorised user)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.disp;
CREATE TABLE raw.disp (
    disp_id text, client_id text, account_id text, type text
);
COPY raw.disp FROM '/data/raw/disp.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.card;
CREATE TABLE raw.card (
    card_id text, disp_id text, type text, issued text
);
COPY raw.card FROM '/data/raw/card.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.loan;
CREATE TABLE raw.loan (
    loan_id text, account_id text, date text, amount text,
    duration text, payments text, status text
);
COPY raw.loan FROM '/data/raw/loan.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
-- The file is called order.asc, but ORDER is a reserved word, so the table
-- is raw.orders.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.orders;
CREATE TABLE raw.orders (
    order_id text, account_id text, bank_to text, account_to text,
    amount text, k_symbol text
);
COPY raw.orders FROM '/data/raw/order.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
-- trans: the big one, every transaction on every account from 1993 to 1998
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.trans;
CREATE TABLE raw.trans (
    trans_id text, account_id text, date text, type text, operation text,
    amount text, balance text, k_symbol text, bank text, account text
);
COPY raw.trans FROM '/data/raw/trans.asc' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- ---------------------------------------------------------------------------
-- Quick sanity check against the counts in the dataset documentation:
-- 77 / 4,500 / 5,369 / 5,369 / 892 / 682 / 6,471 / 1,056,320
-- ---------------------------------------------------------------------------
SELECT 'district' AS table_name, count(*) AS row_count FROM raw.district
UNION ALL SELECT 'account', count(*) FROM raw.account
UNION ALL SELECT 'client',  count(*) FROM raw.client
UNION ALL SELECT 'disp',    count(*) FROM raw.disp
UNION ALL SELECT 'card',    count(*) FROM raw.card
UNION ALL SELECT 'loan',    count(*) FROM raw.loan
UNION ALL SELECT 'orders',  count(*) FROM raw.orders
UNION ALL SELECT 'trans',   count(*) FROM raw.trans;
