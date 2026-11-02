#!/usr/bin/env bash
# Exports the key result tables to results/*.csv, so the findings can be
# read on GitHub without running anything (and to feed make_charts.py).
#
#   ./scripts/export_results.sh            from the Docker container
#   ./scripts/export_results.sh --local    with your own psql

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
DB="${POSTGRES_DB:-berka_bank}"
USER_NAME="${POSTGRES_USER:-postgres}"

if [[ "${1:-}" == "--local" ]]; then
    to_csv() { psql -d "$DB" -v ON_ERROR_STOP=1 -q -c "COPY ($2) TO STDOUT WITH CSV HEADER" > "results/$1.csv"; }
else
    to_csv() { docker compose exec -T db psql -U "$USER_NAME" -d "$DB" -v ON_ERROR_STOP=1 -q \
                   -c "COPY ($2) TO STDOUT WITH CSV HEADER" > "results/$1.csv"; }
fi

mkdir -p results

to_csv portfolio_kpis "SELECT * FROM analytics.v_portfolio_kpis"

to_csv loans_by_status "
    SELECT status_code, status_desc, count(*) AS loans, sum(amount) AS total_amount,
           round(avg(amount)) AS avg_amount
    FROM clean.loan GROUP BY 1, 2 ORDER BY 1"

to_csv bad_rate_by_year "
    SELECT extract(year FROM loan_date)::int AS loan_year, count(*) AS loans,
           count(*) FILTER (WHERE is_default) AS bad_loans,
           round(100.0 * avg(is_default::int), 1) AS bad_loan_rate_pct
    FROM clean.loan GROUP BY 1 ORDER BY 1"

to_csv bad_rate_by_region "SELECT * FROM analytics.v_bad_rate_by_region ORDER BY bad_loan_rate_pct DESC"

to_csv red_flags "
    WITH flags AS (
        SELECT is_default,
               ever_overdrawn AS f1, (min_balance_last_90d < 10000) AS f2,
               (payment_to_income_ratio > 0.20) AS f3, (amount > 200000) AS f4,
               NOT pays_household_bills AS f5, NOT has_second_user AS f6
        FROM analytics.loan_features),
    long AS (
        SELECT 'Overdrawn before the loan' AS red_flag, f1 AS flag, is_default FROM flags
        UNION ALL SELECT 'Balance under 10k in last 90 days', f2, is_default FROM flags
        UNION ALL SELECT 'Repayment over 20% of income', f3, is_default FROM flags
        UNION ALL SELECT 'Loan over 200k CZK', f4, is_default FROM flags
        UNION ALL SELECT 'No household bills paid from account', f5, is_default FROM flags
        UNION ALL SELECT 'Single-user account', f6, is_default FROM flags)
    SELECT red_flag,
           count(*) FILTER (WHERE flag) AS loans_with_flag,
           round(100.0 * avg(is_default::int) FILTER (WHERE flag), 1) AS bad_rate_with_flag,
           round(100.0 * avg(is_default::int) FILTER (WHERE NOT flag), 1) AS bad_rate_without_flag
    FROM long GROUP BY red_flag ORDER BY bad_rate_with_flag DESC"

to_csv min_balance_quintiles "
    WITH q AS (SELECT is_default, min_balance_last_90d,
                      ntile(5) OVER (ORDER BY min_balance_last_90d) AS quintile
               FROM analytics.loan_features)
    SELECT quintile, round(min(min_balance_last_90d)) AS range_from,
           round(max(min_balance_last_90d)) AS range_to, count(*) AS loans,
           round(100.0 * avg(is_default::int), 1) AS bad_rate_pct
    FROM q GROUP BY quintile ORDER BY quintile"

to_csv payment_to_income_quintiles "
    WITH q AS (SELECT is_default, payment_to_income_ratio,
                      ntile(5) OVER (ORDER BY payment_to_income_ratio) AS quintile
               FROM analytics.loan_features)
    SELECT quintile, min(payment_to_income_ratio) AS range_from,
           max(payment_to_income_ratio) AS range_to, count(*) AS loans,
           round(100.0 * avg(is_default::int), 1) AS bad_rate_pct
    FROM q GROUP BY quintile ORDER BY quintile"

to_csv risk_score_distribution "
    SELECT score, count(*) AS loans, count(*) FILTER (WHERE is_default) AS bad_loans,
           round(100.0 * avg(is_default::int), 1) AS bad_rate_pct
    FROM analytics.loan_risk_score GROUP BY score ORDER BY score"

to_csv risk_band_summary "SELECT * FROM analytics.v_risk_band_summary ORDER BY risk_band"

to_csv balance_path_around_loan "
    WITH month_end AS (
        SELECT DISTINCT ON (account_id, date_trunc('month', trans_date))
               account_id, date_trunc('month', trans_date)::date AS month, balance
        FROM clean.transactions
        ORDER BY account_id, date_trunc('month', trans_date), trans_date DESC, trans_id DESC),
    rel AS (
        SELECT l.is_default,
               (extract(year FROM age(m.month, date_trunc('month', l.loan_date))) * 12
                + extract(month FROM age(m.month, date_trunc('month', l.loan_date))))::int AS months_from_loan,
               m.balance
        FROM clean.loan l JOIN month_end m ON m.account_id = l.account_id)
    SELECT months_from_loan,
           round(avg(balance) FILTER (WHERE NOT is_default)) AS avg_balance_good_loans,
           round(avg(balance) FILTER (WHERE is_default))     AS avg_balance_bad_loans
    FROM rel WHERE months_from_loan BETWEEN -6 AND 12
    GROUP BY 1 ORDER BY 1"

to_csv monthly_activity "SELECT * FROM analytics.v_monthly_activity ORDER BY month"

to_csv early_warning_watchlist "
    SELECT loan_id, account_id, client_id, loan_date, amount, monthly_payment,
           est_remaining_czk, round(min_balance_6m) AS min_balance_6m,
           round(balance_at_31_dec_1998) AS balance_now, penalty_charges_6m,
           repayments_6m, signal_count,
           concat_ws(', ',
               CASE WHEN sig_balance_below_one_payment THEN 'balance below one payment' END,
               CASE WHEN sig_penalty_interest THEN 'penalty interest' END,
               CASE WHEN sig_missed_repayments THEN 'missed repayments' END) AS reasons
    FROM analytics.early_warning
    WHERE status_code = 'C' AND signal_count > 0
    ORDER BY signal_count DESC, est_remaining_czk DESC"

echo "Exported:"
ls -1 results/*.csv
