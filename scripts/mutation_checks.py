#!/usr/bin/env python3
"""Mutation checks for the server's concurrency and security guards.

Each entry breaks one guard (a lock, a conditional UPDATE, a version check),
runs the tests that are supposed to catch it, and restores the file. A guard
whose tests still pass is NOT CAUGHT: the test doesn't prove what
docs/review/concurrency.md says it proves.

The ids (M1, M2, ...) are cited in docs/review/concurrency.md, and
test/tspec/docs/review_packet_test.exs keeps the two in sync. When a guard's
code changes, update its pattern here; a pattern that no longer matches is
reported, not skipped.

Usage: make mutation-check, or python3 scripts/mutation_checks.py [M1 M5 ...]
Takes a few minutes; it isn't part of `make test`.
"""
import os
import re
import subprocess
import sys

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "server")

MUTATIONS = [
    ("M1 login attempt limit in the conditional UPDATE",
     "lib/tspec/accounts.ex",
     "c.expires_at > ^now and\n          c.attempts < ^LoginCode.max_attempts(),",
     "c.expires_at > ^now,",
     ["test/tspec/accounts/login_code_concurrency_test.exs"]),
    ("M2 user row lock around the sign-in email cap",
     "lib/tspec/accounts.ex",
     'select: u.id, lock: "FOR UPDATE")',
     "select: u.id)",
     ["test/tspec/accounts/login_code_concurrency_test.exs"]),
    ("M3 magic-link token bound to its email",
     "lib/tspec/accounts.ex",
     "Repo.one(from [_token, user] in query, where: user.email == ^email)",
     "Repo.one(query)",
     ["test/tspec/accounts/api_login_test.exs"]),
    ("M4 sign-out disconnects the token's sockets",
     "lib/tspec_web/controllers/auth_controller.ex",
     '    TSpecWeb.Endpoint.broadcast(TSpecWeb.UserSocket.id_for_token(token), "disconnect", %{})\n',
     "",
     ["test/tspec_web/channels/user_channel_test.exs"]),
    ("M5 :global registration (one session owner per cluster)",
     "lib/tspec/feed/session.ex",
     "GenServer.start_link(__MODULE__, {scope, session_id, opts},\n      name: {:global, name(scope.user.id, session_id)}\n    )",
     "GenServer.start_link(__MODULE__, {scope, session_id, opts})",
     ["test/tspec/feed/session_cluster_test.exs"]),
    ("M6 per-user session cap (make_room)",
     "lib/tspec/feed/session.ex",
     "|> Enum.take(max(length(sessions) - @max_sessions_per_user + 1, 0))",
     "|> Enum.take(0)",
     ["test/tspec/feed/session_test.exs"]),
    ("M7 stale settings broadcasts ignored",
     "lib/tspec/feed/session.ex",
     "      when v > state.settings.version do",
     "      when is_integer(v) do",
     ["test/tspec/feed/session_test.exs"]),
    ("M8 refill merged only under the settings it ran with",
     "lib/tspec/feed/session.ex",
     "defp apply_refill(%{settings: %{version: version}} = state, version, candidates) do",
     "defp apply_refill(state, _version, candidates) do",
     ["test/tspec/feed/session_test.exs"]),
    ("M9 crashed refill task is noticed (DOWN handler)",
     "lib/tspec/feed/session.ex",
     "def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refill_ref: ref} = state) do",
     "def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{refill_ref: :never} = state) do",
     ["test/tspec/feed/session_test.exs"]),
    ("M10 delta-of-delta (each view applied once)",
     "lib/tspec/feed/interests.ex",
     "delta = v.target_delta - v.applied_delta",
     "delta = v.target_delta",
     ["test/tspec/feed/interests_test.exs", "test/tspec/feed/interests_concurrency_test.exs"]),
    ("M11 per-user advisory lock in apply_dirty_views",
     "lib/tspec/feed/interests.ex",
     "    Repo.transact(fn ->\n      lock_user!(user_id)\n\n      views =",
     "    Repo.transact(fn ->\n      views =",
     ["test/tspec/feed/interests_concurrency_test.exs"]),
    ("M12 FOR SHARE on the user row in Events.record",
     "lib/tspec/events.ex",
     'select: u.non_personalized, lock: "FOR SHARE")',
     "select: u.non_personalized)",
     ["test/tspec/feed/interests_concurrency_test.exs"]),
    ("M13 FOR UPDATE on the user row in update_settings",
     "lib/tspec/transparency.ex",
     'do: from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE") |> Repo.one!()',
     "do: from(u in User, where: u.id == ^user_id) |> Repo.one!()",
     ["test/tspec/feed/interests_concurrency_test.exs", "test/tspec/transparency_test.exs"]),
    ("M14 affinity jobs not deduplicated",
     "lib/tspec/feed/affinity_worker.ex",
     "use Oban.Worker, queue: :affinity, max_attempts: 5",
     "use Oban.Worker, queue: :affinity, max_attempts: 5, unique: [period: 60, states: :all]",
     ["test/tspec/feed/interests_concurrency_test.exs"]),
    ("M15 impression ids checked against the caller",
     "lib/tspec/events.ex",
     "      |> verify_impressions(scope)\n",
     "",
     ["test/tspec/feed/ranking_test.exs"]),
    ("M16 final_score is exactly the sum of the trace",
     "lib/tspec/feed/ranker.ex",
     "      final_score: sum(contributions)\n",
     "      final_score: sum(contributions) + 1.0e-9\n",
     ["test/tspec/feed/ranker_test.exs"]),
    ("M17 provider event's conditional status change",
     "lib/tspec/content.ex",
     'where: i.id == ^id and i.status == "processing", select: i)',
     "where: i.id == ^id, select: i)",
     ["test/tspec/content_test.exs"]),
]


def run(selected):
    problems = 0
    for name, path, old, new, tests in MUTATIONS:
        if selected and name.split()[0] not in selected:
            continue
        path = os.path.join(SERVER, path)
        original = open(path).read()
        if original.count(old) != 1:
            print(f"{name}: PATTERN NOT FOUND ({original.count(old)} matches)")
            problems += 1
            continue
        open(path, "w").write(original.replace(old, new))
        try:
            out = subprocess.run(
                ["mix", "test", *tests], cwd=SERVER, capture_output=True, text=True
            ).stdout
        finally:
            open(path, "w").write(original)
        result = re.findall(r"Result: .*", out)
        failed = re.findall(r"^\s+\d+\) (?:test|property) (.+?) \(", out, re.M)
        if not failed:
            problems += 1
        caught = "CAUGHT" if failed else "NOT CAUGHT"
        print(f"{name}: {caught} | {result[-1] if result else 'no result'} | {'; '.join(failed[:3])}")
    return problems


if __name__ == "__main__":
    sys.exit(1 if run(set(sys.argv[1:])) else 0)
