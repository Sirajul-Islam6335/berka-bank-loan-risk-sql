"""
Builds the README charts from the CSVs in results/.

    python scripts/make_charts.py

Needs pandas and matplotlib (pip install pandas matplotlib).
Run ./scripts/export_results.sh first so the CSVs are up to date.
"""

from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
IMAGES = ROOT / "images"
IMAGES.mkdir(exist_ok=True)

# Colours: one blue for "good / neutral", one orange for "bad", grey ink.
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
GRID = "#e4e3df"
BLUE = "#2a78d6"
ORANGE = "#eb6834"

plt.rcParams.update({
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "axes.edgecolor": GRID,
    "axes.labelcolor": INK_2,
    "axes.titlecolor": INK,
    "axes.titlesize": 13,
    "axes.titleweight": "bold",
    "axes.titlelocation": "left",
    "axes.titlepad": 14,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.spines.left": False,
    "axes.grid": True,
    "axes.axisbelow": True,
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "xtick.color": INK_2,
    "ytick.color": INK_2,
    "xtick.major.size": 0,
    "ytick.major.size": 0,
    "font.size": 10.5,
    "font.family": "DejaVu Sans",
    "savefig.dpi": 160,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.25,
})

OVERALL_BAD_RATE = pd.read_csv(RESULTS / "portfolio_kpis.csv")["bad_loan_rate_pct"].iloc[0]


def subtitle(ax, text):
    ax.text(0, 1.02, text, transform=ax.transAxes, color=INK_2, fontsize=10, va="bottom")


# 1. Balance path around the loan date ----------------------------------------
df = pd.read_csv(RESULTS / "balance_path_around_loan.csv")
fig, ax = plt.subplots(figsize=(9, 4.6))
ax.plot(df["months_from_loan"], df["avg_balance_good_loans"] / 1000, color=BLUE, lw=2)
ax.plot(df["months_from_loan"], df["avg_balance_bad_loans"] / 1000, color=ORANGE, lw=2)
ax.axvline(0, color=INK_2, lw=1, ls="--")
ax.text(0.2, 46.5, "loan paid out", color=INK_2, fontsize=9.5)
last = df.iloc[-1]
ax.text(12.3, last["avg_balance_good_loans"] / 1000, "Good loans (A/C)", color=INK, va="center")
ax.text(12.3, last["avg_balance_bad_loans"] / 1000, "Bad loans (B/D)", color=INK, va="center")
ax.set_xlim(-6.3, 15.5)
ax.set_ylim(0, 50)
ax.set_xticks(range(-6, 13, 2))
ax.set_xlabel("Months from loan date")
ax.set_ylabel("Average month-end balance (thousand CZK)")
ax.grid(axis="x", visible=False)
ax.set_title("Accounts that go bad already hold less money before the loan", pad=28)
subtitle(ax, "Average month-end balance, 6 months before to 12 months after the loan")
fig.savefig(IMAGES / "balance_path_around_loan.png")
plt.close(fig)


# 2. Red flags ----------------------------------------------------------------
df = pd.read_csv(RESULTS / "red_flags.csv").sort_values("bad_rate_with_flag")
fig, ax = plt.subplots(figsize=(9, 4.4))
bars = ax.barh(df["red_flag"], df["bad_rate_with_flag"], color=ORANGE, height=0.6)
for bar, rate, n in zip(bars, df["bad_rate_with_flag"], df["loans_with_flag"]):
    ax.text(bar.get_width() + 1.2, bar.get_y() + bar.get_height() / 2,
            f"{rate:.0f}%  ({n} loans)", va="center", color=INK, fontsize=9.5)
ax.axvline(OVERALL_BAD_RATE, color=INK_2, lw=1, ls="--")
ax.text(OVERALL_BAD_RATE + 0.8, -0.75, f"overall rate {OVERALL_BAD_RATE:.1f}%",
        color=INK_2, fontsize=9.5)
ax.set_ylim(-1.0, len(df) - 0.5)
ax.set_xlim(0, 118)
ax.set_xticks(range(0, 101, 20))
ax.set_xticklabels([f"{x}%" for x in range(0, 101, 20)])
ax.grid(axis="y", visible=False)
ax.set_title("Bad loan rate when each red flag is present", pad=28)
subtitle(ax, "Flags use only account history from before the loan date")
fig.savefig(IMAGES / "red_flags.png")
plt.close(fig)


# 3. Risk score ---------------------------------------------------------------
df = pd.read_csv(RESULTS / "risk_score_distribution.csv")
fig, ax = plt.subplots(figsize=(9, 4.4))
bars = ax.bar(df["score"], df["bad_rate_pct"], color=BLUE, width=0.62)
for bar, rate, n in zip(bars, df["bad_rate_pct"], df["loans"]):
    ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 2,
            f"{rate:.0f}%", ha="center", color=INK, fontsize=9.5)
    ax.text(bar.get_x() + bar.get_width() / 2, -9, f"n={n}",
            ha="center", color=INK_2, fontsize=8.5)
ax.set_ylim(-12, 112)
ax.set_yticks(range(0, 101, 25))
ax.set_yticklabels([f"{y}%" for y in range(0, 101, 25)])
ax.set_xticks(df["score"])
ax.set_xlabel("Risk score (0 = no red flags, 8 = all of them)", labelpad=8)
ax.grid(axis="x", visible=False)
ax.spines["bottom"].set_visible(False)
ax.set_title("The simple risk score ranks loans cleanly", pad=28)
subtitle(ax, "Bad loan rate at each score, with number of loans underneath")
fig.savefig(IMAGES / "risk_score.png")
plt.close(fig)


# 4. Lowest balance in the last 90 days, by quintile -----------------------------
df = pd.read_csv(RESULTS / "min_balance_quintiles.csv")
labels = [f"{a/1000:,.0f}k to {b/1000:,.0f}k" for a, b in zip(df["range_from"], df["range_to"])]
fig, ax = plt.subplots(figsize=(9, 4.2))
colors = [ORANGE if i == 0 else BLUE for i in range(len(df))]
bars = ax.bar(labels, df["bad_rate_pct"], color=colors, width=0.6)
for bar, rate in zip(bars, df["bad_rate_pct"]):
    ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1,
            f"{rate:.1f}%", ha="center", color=INK, fontsize=9.5)
ax.set_ylim(0, 42)
ax.set_yticks(range(0, 41, 10))
ax.set_yticklabels([f"{y}%" for y in range(0, 41, 10)])
ax.set_xlabel("Lowest balance in the 90 days before the loan (CZK), fifths of all loans")
ax.grid(axis="x", visible=False)
ax.set_title("Being low on cash just before the loan is the biggest warning sign", pad=28)
subtitle(ax, "Bad loan rate by fifth of lowest recent balance (137 loans per bar)")
fig.savefig(IMAGES / "min_balance_quintiles.png")
plt.close(fig)


# 5. Bad loan rate by year ----------------------------------------------------
df = pd.read_csv(RESULTS / "bad_rate_by_year.csv")
fig, ax = plt.subplots(figsize=(9, 4))
colors = [BLUE] * (len(df) - 1) + ["#9ec5f4"]
bars = ax.bar(df["loan_year"].astype(str), df["bad_loan_rate_pct"], color=colors, width=0.6)
for bar, rate, n in zip(bars, df["bad_loan_rate_pct"], df["loans"]):
    ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
            f"{rate:.1f}%", ha="center", color=INK, fontsize=9.5)
    ax.text(bar.get_x() + bar.get_width() / 2, -1.9, f"{n} loans",
            ha="center", color=INK_2, fontsize=8.5)
ax.text(5, 5.2, "too new to\nhave gone bad", ha="center", color=INK_2, fontsize=9)
ax.set_ylim(-3, 24)
ax.set_yticks(range(0, 21, 5))
ax.set_yticklabels([f"{y}%" for y in range(0, 21, 5)])
ax.tick_params(axis="x", pad=14)
ax.grid(axis="x", visible=False)
ax.spines["bottom"].set_visible(False)
ax.set_title("Bad loan rate by year the loan was granted", pad=28)
subtitle(ax, "Steady at 13-14% from 1994 to 1997")
fig.savefig(IMAGES / "bad_rate_by_year.png")
plt.close(fig)

print("Charts written to", IMAGES)
for p in sorted(IMAGES.glob("*.png")):
    print("  ", p.name)
