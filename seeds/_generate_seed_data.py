#!/usr/bin/env python3
"""
Deterministic generator for ZOOM_AI_POC_V2 enriched raw seed data.

Produces 6 CSVs in this directory (seeds/), loaded into ZOOM_AI_POC_V2.RAW via `dbt seed`:
  - phone_history.csv, sms_history.csv, chat_history.csv, email_history.csv, video_history.csv
      columns: record_id, account_id, agent_hash_id, engagement_id, channel,
               start_time, duration_sec, direction, final_outcome, sla_achieved, _loaded_at
  - account_dim.csv
      columns: account_id, account_name, region, segment, is_licensed, _loaded_at

Design goals:
  * ~10 accounts, ~30 users, ~40-day span, 100-150 rows per channel (~500-750 total).
  * region in {NAMER, APAC, EMEA, LATAM}; segment in 1..5; is_licensed bool -- one fixed value per account.
  * 3-5 "power users" active on >=16 distinct days inside a 28-day window so users_active_16plus_days > 0.
  * Deterministic: fixed RNG seed.
"""
import csv
import os
import random
from datetime import datetime, timedelta

SEED = 20260601
random.seed(SEED)

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- Reference window -------------------------------------------------------
# 40-day span. Anchor end near "today" of the POC (2026-06-01). Use NTZ-style strings.
END_DATE = datetime(2026, 5, 31)
SPAN_DAYS = 40
START_DATE = END_DATE - timedelta(days=SPAN_DAYS - 1)  # 2026-04-22
LOADED_AT = "2026-06-01 00:00:00"

REGIONS = ["NAMER", "APAC", "EMEA", "LATAM"]

# ---- Accounts (~10) ---------------------------------------------------------
N_ACCOUNTS = 10
accounts = []
for i in range(1, N_ACCOUNTS + 1):
    acct_id = f"ACC{i:03d}"
    accounts.append({
        "account_id": acct_id,
        "account_name": f"Account {i:03d} Inc",
        "region": REGIONS[(i - 1) % len(REGIONS)],     # deterministic spread across all 4
        "segment": ((i - 1) % 5) + 1,                  # 1..5
        "is_licensed": (i % 2 == 0),                   # alternating
        "_loaded_at": LOADED_AT,
    })

# ---- Users (~30), each mapped to one account -------------------------------
N_USERS = 30
users = []
for u in range(1, N_USERS + 1):
    acct = accounts[(u - 1) % N_ACCOUNTS]              # round-robin -> every account gets >=3 users
    users.append({
        "agent_hash_id": f"USR{u:04d}",
        "account_id": acct["account_id"],
    })

# Designate 4 power users (active >=16 distinct days in a 28-day window).
POWER_USER_IDXS = [0, 7, 14, 21]                       # indexes into `users`
power_user_ids = {users[i]["agent_hash_id"] for i in POWER_USER_IDXS}

# ---- Channel config ---------------------------------------------------------
# duration_sec ranges are channel-realistic.
CHANNELS = {
    "phone_history": {"channel": "PHONE", "dur": (30, 1800)},
    "sms_history":   {"channel": "SMS",   "dur": (5, 120)},
    "chat_history":  {"channel": "CHAT",  "dur": (60, 1200)},
    "email_history": {"channel": "EMAIL", "dur": (120, 3600)},
    "video_history": {"channel": "VIDEO", "dur": (300, 5400)},
}
DIRECTIONS = ["Inbound", "Outbound"]
OUTCOMES = ["Answered", "Missed", "Resolved", "Closed"]

# Per-channel target row counts in [100,150].
ROWS_PER_CHANNEL = {
    "phone_history": 150,
    "sms_history":   120,
    "chat_history":  130,
    "email_history": 110,
    "video_history": 100,
}

# Pre-compute active-day sets.
# Power users: active on >=16 distinct days within the FIRST 28-day sub-window
# (START_DATE .. START_DATE+27). Pick 18 distinct days for headroom.
all_offsets = list(range(SPAN_DAYS))
power_window_offsets = list(range(0, 28))             # first 28 days = one 28-day window
power_active_offsets = {}
for i in POWER_USER_IDXS:
    uid = users[i]["agent_hash_id"]
    days = sorted(random.sample(power_window_offsets, 18))   # 18 distinct days in a 28-day window
    power_active_offsets[uid] = set(days)

# Regular users: sparse, 1-8 distinct active days scattered across full span.
regular_active_offsets = {}
for idx, usr in enumerate(users):
    if idx in POWER_USER_IDXS:
        continue
    uid = usr["agent_hash_id"]
    n_days = random.randint(1, 8)
    regular_active_offsets[uid] = set(random.sample(all_offsets, n_days))


def day_str(offset, rng):
    """Build a timestamp string on a given day offset with a random time."""
    d = START_DATE + timedelta(days=offset)
    secs = rng.randint(8 * 3600, 18 * 3600)            # business hours-ish
    ts = d + timedelta(seconds=secs)
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def pick_user_and_day(rng):
    """Pick a (user, day_offset) weighted so power users fire on their active days."""
    # 45% of interactions come from power users (on their active days), rest from regulars.
    if rng.random() < 0.45 and power_active_offsets:
        uid = rng.choice(list(power_active_offsets.keys()))
        offset = rng.choice(sorted(power_active_offsets[uid]))
    else:
        uid = rng.choice(list(regular_active_offsets.keys()))
        offsets = regular_active_offsets[uid]
        offset = rng.choice(sorted(offsets)) if offsets else rng.choice(all_offsets)
    return uid, offset


user_account = {u["agent_hash_id"]: u["account_id"] for u in users}

record_counter = 0
engagement_counter = 0
# NOTE: headers are UPPERCASE. `direction` and `is_licensed` are Snowflake
# reserved words; seeds are configured with quote_columns: true, so the column
# identifiers are created exactly as written. Uppercasing keeps them matching
# Snowflake's default identifier casing so existing source()/ref() SQL resolves.
HISTORY_HEADER = [
    "RECORD_ID", "ACCOUNT_ID", "AGENT_HASH_ID", "ENGAGEMENT_ID", "CHANNEL",
    "START_TIME", "DURATION_SEC", "DIRECTION", "FINAL_OUTCOME", "SLA_ACHIEVED", "_LOADED_AT",
]

# Use a dedicated RNG stream for row generation (after active-day sets fixed) for determinism.
gen_rng = random.Random(SEED + 1)

def make_row(uid, offset, cfg):
    global record_counter, engagement_counter
    record_counter += 1
    engagement_counter += 1
    acct = user_account[uid]
    dur = gen_rng.randint(*cfg["dur"])
    return {
        "RECORD_ID": f"REC{record_counter:06d}",
        "ACCOUNT_ID": acct,
        "AGENT_HASH_ID": uid,
        "ENGAGEMENT_ID": f"ENG{engagement_counter:06d}",
        "CHANNEL": cfg["channel"],
        "START_TIME": day_str(offset, gen_rng),
        "DURATION_SEC": dur,
        "DIRECTION": gen_rng.choice(DIRECTIONS),
        "FINAL_OUTCOME": gen_rng.choice(OUTCOMES),
        "SLA_ACHIEVED": str(gen_rng.choice([True, False])).upper(),   # TRUE/FALSE
        "_LOADED_AT": LOADED_AT,
    }


# Guarantee every power-user active day produces at least one interaction.
# Spread these guaranteed rows round-robin across the 5 channels so each power
# user genuinely has >=16 distinct active days regardless of random sampling.
GUARANTEED = []  # list of (uid, offset, table)
gd_channel_cycle = list(CHANNELS.keys())
gi = 0
for i in POWER_USER_IDXS:
    uid = users[i]["agent_hash_id"]
    for offset in sorted(power_active_offsets[uid]):
        table = gd_channel_cycle[gi % len(gd_channel_cycle)]
        GUARANTEED.append((uid, offset, table))
        gi += 1

guaranteed_by_table = {t: [] for t in CHANNELS}
for uid, offset, table in GUARANTEED:
    guaranteed_by_table[table].append((uid, offset))

for table, cfg in CHANNELS.items():
    n_rows = ROWS_PER_CHANNEL[table]
    rows = []
    # First, emit guaranteed power-user active-day rows for this channel.
    for uid, offset in guaranteed_by_table[table]:
        rows.append(make_row(uid, offset, cfg))
    # Then fill the remainder with weighted random interactions.
    while len(rows) < n_rows:
        uid, offset = pick_user_and_day(gen_rng)
        rows.append(make_row(uid, offset, cfg))
    path = os.path.join(HERE, f"{table}.csv")
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=HISTORY_HEADER)
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {path}: {len(rows)} rows")

# ---- account_dim.csv --------------------------------------------------------
dim_path = os.path.join(HERE, "account_dim.csv")
DIM_HEADER = ["ACCOUNT_ID", "ACCOUNT_NAME", "REGION", "SEGMENT", "IS_LICENSED", "_LOADED_AT"]
with open(dim_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=DIM_HEADER)
    w.writeheader()
    for a in accounts:
        w.writerow({
            "ACCOUNT_ID": a["account_id"],
            "ACCOUNT_NAME": a["account_name"],
            "REGION": a["region"],
            "SEGMENT": a["segment"],
            "IS_LICENSED": str(a["is_licensed"]).upper(),
            "_LOADED_AT": a["_loaded_at"],
        })
print(f"wrote {dim_path}: {len(accounts)} rows")

# ---- Sanity: report power-user active-day counts in a 28-day window ---------
print("\nPower-user distinct active days in first 28-day window:")
for i in POWER_USER_IDXS:
    uid = users[i]["agent_hash_id"]
    print(f"  {uid} (acct {user_account[uid]}): {len(power_active_offsets[uid])} days")
