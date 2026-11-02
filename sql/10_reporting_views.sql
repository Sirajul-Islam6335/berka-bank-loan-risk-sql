-- =============================================================================
-- 10_reporting_views.sql
--
-- A few tidy views over the analysis, ready to plug into Power BI, Tableau
-- or Metabase (or just to export as CSV).
-- =============================================================================


-- Headline KPIs, one row
CREATE OR REPLACE VIEW analytics.v_portfolio_kpis AS
SELECT
    (SELECT count(*) FROM clean.client)                        AS clients,
    (SELECT count(*) FROM clean.account)                       AS accounts,
    count(*)                                                   AS loans,
    sum(amount)                                                AS total_lent_czk,
    count(*) FILTER (WHERE is_default)                         AS bad_loans,
    round(100.0 * avg(is_default::int), 1)                     AS bad_loan_rate_pct,
    round(100.0 * sum(amount) FILTER (WHERE is_default) / sum(amount), 1) AS bad_loan_value_pct,
    (SELECT count(*) FROM analytics.early_warning WHERE status_code = 'C' AND signal_count > 0)
                                                               AS loans_on_watchlist
FROM clean.loan;


-- Bad loan rate by region (for a map or bar chart)
CREATE OR REPLACE VIEW analytics.v_bad_rate_by_region AS
SELECT
    region,
    count(*)                                  AS loans,
    count(*) FILTER (WHERE is_default)        AS bad_loans,
    round(100.0 * avg(is_default::int), 1)    AS bad_loan_rate_pct,
    round(avg(amount))                        AS avg_loan_czk
FROM analytics.loan_features
GROUP BY region;


-- Monthly bank activity
CREATE OR REPLACE VIEW analytics.v_monthly_activity AS
SELECT
    date_trunc('month', trans_date)::date             AS month,
    count(DISTINCT account_id)                         AS active_accounts,
    count(*)                                           AS transactions,
    round(sum(amount) FILTER (WHERE direction = 'Credit')) AS money_in,
    round(sum(amount) FILTER (WHERE direction = 'Debit'))  AS money_out,
    count(*) FILTER (WHERE balance < 0)                AS overdrawn_txns
FROM clean.transactions
GROUP BY 1;


-- Risk score bands
CREATE OR REPLACE VIEW analytics.v_risk_band_summary AS
SELECT
    risk_band,
    count(*)                                  AS loans,
    count(*) FILTER (WHERE is_default)        AS bad_loans,
    round(100.0 * avg(is_default::int), 1)    AS bad_rate_pct,
    sum(amount)                               AS amount_czk
FROM analytics.loan_risk_score
GROUP BY risk_band;


-- One row per loan with everything a dashboard user might want to filter by
CREATE OR REPLACE VIEW analytics.v_loan_detail AS
SELECT
    f.loan_id,
    f.account_id,
    f.client_id,
    f.loan_date,
    extract(year FROM f.loan_date)::int  AS loan_year,
    f.amount,
    f.duration_months,
    f.monthly_payment,
    f.status_code,
    f.loan_state,
    f.is_default,
    f.gender,
    f.age_at_loan,
    f.region,
    f.district_name,
    f.has_second_user,
    f.card_before_loan,
    f.payment_to_income_ratio,
    f.min_balance_last_90d,
    f.ever_overdrawn,
    r.score       AS risk_score,
    r.risk_band,
    coalesce(e.signal_count, 0) AS warning_signals
FROM analytics.loan_features f
JOIN analytics.loan_risk_score r USING (loan_id)
LEFT JOIN analytics.early_warning e USING (loan_id);


-- Quick check that every view returns rows
SELECT 'v_portfolio_kpis'     AS view_name, count(*) AS rows FROM analytics.v_portfolio_kpis
UNION ALL SELECT 'v_bad_rate_by_region', count(*) FROM analytics.v_bad_rate_by_region
UNION ALL SELECT 'v_monthly_activity',   count(*) FROM analytics.v_monthly_activity
UNION ALL SELECT 'v_risk_band_summary',  count(*) FROM analytics.v_risk_band_summary
UNION ALL SELECT 'v_loan_detail',        count(*) FROM analytics.v_loan_detail;
