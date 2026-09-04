#!/usr/bin/env python3
"""Write a fictional ~/.claude/projects tree, for the README screenshots.

The app reads real conversations, which are nobody's business but yours - so the
screenshots are taken against this instead. Point the app at it with
DEJAVU_PROJECTS_DIR and DEJAVU_INSIGHTS.

    python3 Scripts/demo-data.py /tmp/demo
"""
import json, os, sys, time

now = time.time()
H = 3600


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z"


def user(text, t, cwd, branch):
    return {"type": "user", "cwd": cwd, "gitBranch": branch, "timestamp": iso(t),
            "message": {"role": "user", "content": text}}


def claude(text, t, cwd, branch, tools=(), usage=(1800, 640)):
    content = [{"type": "text", "text": text}]
    for name, path in tools:
        content.append({"type": "tool_use", "name": name, "id": "tu_%d" % len(content),
                        "input": {"file_path": path}})
    return {"type": "assistant", "cwd": cwd, "gitBranch": branch, "timestamp": iso(t),
            "message": {"role": "assistant", "model": "claude-opus-5",
                        "content": content,
                        "usage": {"input_tokens": usage[0],
                                  "cache_read_input_tokens": usage[0] * 6,
                                  "output_tokens": usage[1]}}}


IDEMPOTENCY_PLAN = """Here's the plan for **idempotent order creation**.

## The mechanism

The client sends an `Idempotency-Key` header. We store the key with the response, so a retry replays the original result instead of creating a second order.

| Step | Behaviour |
|---|---|
| First request | Insert key, process, store response |
| Retry (same key) | Return the stored response, `200` |
| Retry (in flight) | Return `409 Conflict` |

```sql
CREATE TABLE idempotency_keys (
  key        TEXT PRIMARY KEY,
  response   JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

Key points:

- The insert must happen in the *same transaction* as the order write.
- Expire keys after 24h with a scheduled cleanup.
- Scope keys per-customer so one tenant can't guess another's key."""

ORDERS = "/Users/dev/code/orders-api"
STORE = "/Users/dev/code/web-storefront"
INFRA = "/Users/dev/infra/platform-terraform"
HOME = "/Users/dev/side/homelab"

# (id, title-carrying first user line, cwd, branch, age in hours, turns)
SESSIONS = [
    ("7c1f4a90-1111-4aaa-8001-000000000001", ORDERS, "feat/idempotency-keys", 0.22, [
        ("u", "Add idempotency keys to the orders endpoint so retries don't double-charge."),
        ("a", IDEMPOTENCY_PLAN, [("Read", ORDERS + "/src/orders/routes.py"),
                                ("Edit", ORDERS + "/src/orders/routes.py")]),
        ("u", "What happens if the process dies mid-write?"),
        ("a", "The transaction rolls back, so neither the key nor the order is stored. "
              "The retry is then a first request again - which is the behaviour you want.",
         [("Write", ORDERS + "/migrations/0007_idempotency_keys.sql")]),
    ]),
    ("7c1f4a90-2222-4aaa-8002-000000000002", ORDERS, "main", 2.1, [
        ("u", "Why are checkout latencies spiking at 11pm?"),
        ("a", "The nightly settlement job holds a table lock on `orders` for ~40s. "
              "Checkout writes queue behind it. Moving the job to a read replica clears it.",
         [("Read", ORDERS + "/jobs/settlement.py")]),
    ]),
    ("7c1f4a90-3333-4aaa-8003-000000000003", STORE, "main", 3.4, [
        ("u", "The cart drawer keeps remounting on route change."),
        ("a", "The drawer lives inside the route subtree, so every navigation unmounts it. "
              "Hoisting it above the router keeps one instance alive.",
         [("Edit", STORE + "/src/components/CartDrawer.tsx")]),
    ]),
    ("7c1f4a90-4444-4aaa-8004-000000000004", INFRA, "main", 5.2, [
        ("u", "Split the staging and prod Terraform state files."),
        ("a", "One state for both environments means a staging apply can touch prod. "
              "Per-environment backends with separate lock tables fixes that.",
         [("Read", INFRA + "/environments/prod/backend.tf")]),
    ]),
    ("7c1f4a90-5555-4aaa-8005-000000000005", HOME, "main", 19.0, [
        ("u", "Backups quietly stopped three weeks ago."),
        ("a", "The restic cron exits 0 even when the repository is unreachable. "
              "Added a dead-man's switch that alerts when no snapshot lands in 36h.",
         [("Write", HOME + "/ansible/roles/backup/tasks/main.yml")]),
    ]),
    ("7c1f4a90-6666-4aaa-8006-000000000006", STORE, "feat/checkout-retries", 26.0, [
        ("u", "Wire the storefront checkout client to send idempotency keys."),
        ("a", "Generate a UUID per checkout attempt, keep it in session storage, and reuse "
              "it for every retry of that attempt. Clear it once the order is confirmed.",
         [("Edit", STORE + "/src/api/checkout.ts")]),
    ]),
    ("7c1f4a90-7777-4aaa-8007-000000000007", STORE, "main", 33.0, [
        ("u", "Cache the product feed so the storefront stops refetching it per page."),
        ("a", "A 5-minute stale-while-revalidate cache in front of the feed cuts it to one "
              "fetch per window, and the feed only changes on publish.",
         [("Edit", STORE + "/src/api/feed.ts")]),
    ]),
    ("7c1f4a90-8888-4aaa-8008-000000000008", INFRA, "main", 44.0, [
        ("u", "Rotate the Terraform state encryption key."),
        ("a", "Re-encrypt with the new KMS key, keep the old one enabled for decrypt until "
              "every workspace has been applied once, then retire it.",
         [("Read", INFRA + "/modules/state/kms.tf")]),
    ]),
]

# Older conversations: outside the 48h list, but they give the activity strip
# something to draw across the four-week window.
OLDER = [
    (4.5 * 24, ORDERS, "Add a partial-refund path to the payments client"),
    (5.2 * 24, STORE, "Make the search box keyboard-navigable"),
    (6.0 * 24, INFRA, "Pin the provider versions before the next apply"),
    (9.5 * 24, HOME, "Move the media library onto the new pool"),
    (11.0 * 24, ORDERS, "Batch the webhook fan-out per customer"),
    (12.5 * 24, STORE, "Trim the bundle: the date library is half of it"),
    (17.0 * 24, INFRA, "Give each environment its own lock table"),
    (18.2 * 24, ORDERS, "Retry the settlement job instead of failing the night"),
    (23.0 * 24, HOME, "Alert when a disk crosses 85 percent"),
]


def encode(cwd):
    return cwd.replace("/", "-")


def write(out):
    projects = os.path.join(out, "projects")
    for sid, cwd, branch, age, turns in SESSIONS:
        d = os.path.join(projects, encode(cwd))
        os.makedirs(d, exist_ok=True)
        t = now - age * H
        lines = []
        for i, turn in enumerate(turns):
            ts = t + i * 240
            if turn[0] == "u":
                lines.append(user(turn[1], ts, cwd, branch))
            else:
                lines.append(claude(turn[1], ts, cwd, branch, turn[2] if len(turn) > 2 else ()))
        with open(os.path.join(d, sid + ".jsonl"), "w") as f:
            for line in lines:
                f.write(json.dumps(line) + "\n")

    for n, (age, cwd, title) in enumerate(OLDER):
        d = os.path.join(projects, encode(cwd))
        os.makedirs(d, exist_ok=True)
        t = now - age * H
        sid = "7c1f4a90-9999-4aaa-90%02d-0000000090%02d" % (n, n)
        with open(os.path.join(d, sid + ".jsonl"), "w") as f:
            f.write(json.dumps(user(title + ".", t, cwd, "main")) + "\n")
            f.write(json.dumps(claude("Done - see the diff above.", t + 300, cwd, "main")) + "\n")

    insights = {
        "generated": now,
        "summaries": {
            SESSIONS[0][0]: "Designed idempotency keys so retried order requests can't double-charge",
            SESSIONS[1][0]: "Traced nightly checkout latency spikes to a settlement job holding a table lock",
            SESSIONS[2][0]: "Fixed the cart drawer remounting by hoisting it above the router",
            SESSIONS[3][0]: "Split shared Terraform state into per-environment states",
            SESSIONS[4][0]: "Found backups failing silently; added failure alerts and a dead-man's switch",
            SESSIONS[5][0]: "Added idempotency key handling to the storefront checkout client",
            SESSIONS[6][0]: "Cached the product feed to stop per-page refetching",
            SESSIONS[7][0]: "Rotated the Terraform state encryption key without downtime",
        },
        "clusters": [
            {"label": "Idempotent checkout",
             "session_ids": [SESSIONS[0][0], SESSIONS[5][0]]},
            {"label": "Silent failures",
             "session_ids": [SESSIONS[1][0], SESSIONS[4][0]]},
            {"label": "Terraform state & secrets",
             "session_ids": [SESSIONS[3][0], SESSIONS[7][0]]},
            {"label": "Storefront rendering",
             "session_ids": [SESSIONS[2][0], SESSIONS[6][0]]},
        ],
    }
    with open(os.path.join(out, "insights.json"), "w") as f:
        json.dump(insights, f, indent=2)

    print("projects: %s" % projects)
    print("insights: %s" % os.path.join(out, "insights.json"))
    print("open first: %s" % SESSIONS[0][0])


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dejavu-demo"
    os.makedirs(out, exist_ok=True)
    write(out)
