# List available recipes
default:
    @just --list

# Run the web app (Postgres, port 4000)
server:
    iex -S mix phx.server

# Make a fresh worktree runnable. Idempotent; safe to re-run.
#
# A new worktree looks complete and is not. Three things are missing and each
# one fails later than it should:
#
#   envs/                     — config/runtime.exs loads it with Dotenvy. Absent,
#                               the harness boots and refuses every hook with
#                               "no credential", which reads as a broken harness.
#   code_my_spec_test_repos/  — the drill and devops spex fixtures resolve
#                               against it by relative path.
#   the test database         — config/test.exs gives every worktree its own
#                               (code_my_spec_test_<name>), deliberately, so
#                               agents cannot re-schema each other. Nothing
#                               creates it, and the first `mix test` fails in
#                               bulk with an undefined column.
#
# 2fb10199 reports all three as round trips a subagent had to work out for
# itself, one at a time, and it is the third that is expensive: a stale or
# missing database presents as broken code across contexts nobody touched.
#
# Symlinks rather than copies. `envs` holds secrets that must not be duplicated
# per worktree, and the test repos are a fixture several worktrees share; a copy
# would drift and the drift is silent.
#
# **Run this after a rebase, not only once.** Every step is idempotent, and the
# two that matter — deps and migrations — are exactly the per-worktree state a
# rebase silently invalidates. A sibling's commit moves `mix.lock` and `mix`
# refuses before it runs anything (`66e30d85`); a sibling's migration lands and
# the suite fails in bulk on a column nobody touched (`f58acb37`, and `2fb10199`
# above for the first-run version of the same miss). Both are one command, and
# both cost a diagnosis first because they arrive in the middle of unrelated
# work and read as the worktree being broken.
worktree-setup:
    #!/usr/bin/env bash
    set -euo pipefail

    main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
    here="$(git rev-parse --show-toplevel)"

    if [ "$main" = "$here" ]; then
      echo "This is the main checkout, not a worktree — nothing to link." >&2
      exit 0
    fi

    echo "→ worktree: $here"
    echo "→ main:     $main"

    # -n so a re-run replaces the symlink rather than creating one inside the
    # directory it already points at, which is what `ln -sf` does to a link that
    # resolves to a directory and is a genuinely confusing mess to unpick.
    ln -sfn "$main/envs" "$here/envs"
    echo "  envs -> $main/envs"

    repos="$(dirname "$main")/code_my_spec_test_repos"
    if [ -d "$repos" ]; then
      ln -sfn "$repos" "$here/code_my_spec_test_repos"
      echo "  code_my_spec_test_repos -> $repos"
    else
      echo "  (no $repos — skipping; drill and devops spex will not run here)"
    fi

    # Deps before the database, because a lock mismatch stops `mix` before it
    # loads anything — including `ecto.migrate`. So the two steps below cannot
    # even report their own problem while this one is outstanding.
    #
    # `66e30d85`: twice in a week a rebase brought a `mix.lock` entry from
    # another worktree's commit and every `mix` invocation here refused before
    # running anything. Not the task — the tool. Recovery is one command, and
    # the cost is that it arrives in the middle of unrelated work and reads as
    # the worktree being broken.
    echo "→ deps"
    MIX_ENV=test elixir -S mix deps.get

    # `elixir -S mix`, not `mix`: a bare `mix` in a worktree resolves against the
    # main checkout and would create the wrong tree's database.
    echo "→ test database"
    MIX_ENV=test elixir -S mix ecto.create --quiet
    MIX_ENV=test elixir -S mix ecto.migrate

    echo
    # Single quotes: backticks inside a double-quoted bash string are command
    # substitution, so the friendly closing message would have *run* the suite.
    echo 'Ready. `mix test` and `mix spex` should both work from here now.'

# Pull main and restart the dev server, from any worktree.
refresh port="4000":
    #!/usr/bin/env bash
    set -euo pipefail

    # 
    # The :4000 server runs the *main* checkout, not the worktree an agent works in,
    # so a fix that is committed, pushed and green can be absent from every response
    # an agent sees — and the responses that matter are messages about correctness,
    # where a stale one reads as "the fix does not work" rather than "the build is
    # old". Three of those cost a diversion each in one session before
    # `[Boot] serving <sha>` existed to answer it in one line.
    # 
    # Doing it by hand needs a directory an agent in a worktree cannot cd to, so
    # this exists to be run from anywhere in the repo. `--git-common-dir` resolves
    # to the main checkout's `.git` from inside any worktree, which is what makes
    # that possible.
    # 
    # It refuses on a dirty checkout rather than pulling over someone's uncommitted
    # work: several agents share that directory, and a rebase on top of a
    # half-finished change is the one outcome nobody can undo from here.


    main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
    echo "→ main checkout: $main"

    # Tracked, non-submodule changes only. Untracked files are not disturbed by
    # a fast-forward, and `.code_my_spec` is a submodule whose pointer moves
    # whenever an agent commits a spec — refusing on either makes this refuse
    # essentially always, which is the same as not having it. What it is for is
    # the case that actually turned up: seven modified files under `config/` and
    # `lib/`, mid-change, belonging to someone else.
    dirty="$(git -C "$main" status --porcelain --untracked-files=no --ignore-submodules=all)"
    if [ -n "$dirty" ]; then
        echo "✗ refusing: the main checkout has uncommitted work." >&2
        echo "$dirty" >&2
        echo "" >&2
        echo "  Another agent is probably mid-change there. Commit or stash it," >&2
        echo "  or restart by hand once it is clear." >&2
        exit 1
    fi

    before="$(git -C "$main" rev-parse --short HEAD)"
    git -C "$main" pull --ff-only
    after="$(git -C "$main" rev-parse --short HEAD)"
    echo "→ $before → $after"

    # Only when the lock actually moved. `deps.get` plus the compile it triggers
    # is most of this recipe's wall time — the first real run took over ten
    # minutes — and the lock is unchanged on the majority of refreshes.
    #
    # Not skippable in general, though: a lock that moved and is not fetched
    # turns into "Unchecked dependencies" on the next mix invocation, which
    # several analyzers report as findings rather than as an environment
    # problem. That is what 6d9523a9 and 3430012e were about.
    if [ -n "$(git -C "$main" diff --name-only "$before".."$after" -- mix.lock)" ]; then
        echo "→ mix.lock moved, fetching deps"
        ( cd "$main" && mix deps.get )
    else
        echo "→ mix.lock unchanged in this pull"
    fi

    # Asking whether the build is *satisfiable*, not whether this pull moved the
    # lock. Those are different questions and only the second was being asked.
    #
    # Measured: main was already at the new commit — somebody else had pulled —
    # so `before` equalled `after`, the lock diff was empty, deps.get was
    # skipped, and the server refused to boot with
    #
    #   Unchecked dependencies for environment dev:
    #   * req (Hex package)
    #     the dependency does not match the requirement "~> 0.7", got "0.5.17"
    #
    # for three consecutive restarts. `mix deps.get` did not fix it either and
    # answered "All dependencies have been fetched", because the stale copy was
    # not in `deps/` — it was the compiled artifact in `_build/dev/lib/req`,
    # which `deps.get` never touches. `deps.compile` is what does.
    #
    # `loadpaths` is the cheap way to ask: it is what every mix task runs first,
    # and it is the exact check that was failing.
    if ! ( cd "$main" && mix loadpaths >/dev/null 2>&1 ); then
        echo "→ deps do not satisfy mix.exs — fetching and recompiling"
        ( cd "$main" && mix deps.get && mix deps.compile )
    fi

    # By port, not by name: several beams run on this machine and only one of
    # them is serving {{port}}.
    pid="$(lsof -nP -iTCP:{{port}} -sTCP:LISTEN -t || true)"
    if [ -n "$pid" ]; then
        echo "→ stopping $pid on {{port}}"
        kill "$pid"
        for _ in $(seq 1 30); do
            lsof -nP -iTCP:{{port}} -sTCP:LISTEN -t >/dev/null 2>&1 || break
            sleep 1
        done
    fi

    log="$HOME/.codemyspec/phx_{{port}}.restart.log"

    # Migrations, after the old server is down and before the new one is up.
    #
    # `Phoenix.Ecto.CheckRepoStatus` refuses *every request* with
    # `PendingMigrationError` while the dev database is behind — a 503 on the
    # MCP endpoint, so every agent on this machine loses its tools at once and
    # the message they see names a harness, not a migration:
    #
    #   The harness could not reach http://localhost:4000 to find out where
    #   <id> is: {:error, {:refused, 503}}
    #
    # An agent committing a migration from a worktree does so against its own
    # test database, and nothing runs it on dev. Measured tonight: pushing
    # `add_qa_script_to_file_role`, then `just refresh`, left :4000 answering
    # 503 to everything — the recipe that exists to make the server current had
    # pulled the migration and not run it.
    #
    # Unconditional rather than diffed against the pull, for the reason the deps
    # check above already learned: when somebody else has already pulled,
    # `before` equals `after` and the diff is empty while the database is still
    # behind. `ecto.migrate` with nothing pending is one query.
    #
    # After the kill, because a `mix` invocation takes the build lock and that
    # is what 500s a running server.
    echo "→ migrations"
    ( cd "$main" && mix ecto.migrate )

    # Rotated here because nothing else rotates it.
    #
    # CLAUDE.md documents rotation as "10 MB x 3 by :logger_std_h", and that is
    # true of the logfmt handlers — server.log, web.log and harness.log all sit
    # at their cap with .0/.1/.2 siblings. These are raw stdout redirects and
    # were opened with `>>`, so they grew for as long as anyone kept restarting:
    # 1.8G and 743M between the two of them, on a disk with 5.2 GiB free, and
    # back to 189M within a day of being truncated.
    #
    # One previous run is the right amount to keep. The failure these answer is
    # "it did not come up just now", and the run before is occasionally worth
    # comparing against; the forty before that never were.
    #
    # `mv` rather than a copy so a still-dying server keeps writing to the same
    # inode — it follows its old fd into the .1 file instead of reopening the
    # fresh one and interleaving with its replacement.
    mv -f "$log" "$log.1" 2>/dev/null || true

    # `</dev/null` matters as much as the output redirect. Without it the server
    # inherits the caller's stdin, and a caller that waits for every writer to
    # close — a CI step, an agent's shell tool — hangs for its whole timeout on
    # a recipe that has already exited. Measured: the recipe takes 3s, and
    # invoking it without this looked like ten minutes and an empty log.
    ( cd "$main" && exec </dev/null >"$log" 2>&1; nohup mix phx.server & )
    echo "→ starting, logging to $log"

    # A short wait, not a long one. The server is already detached — this poll
    # only exists so the common case can say "it came up" instead of "go and
    # check". Ninety rounds of it meant a caller held the recipe for three
    # minutes on the one path where something was wrong, which is exactly when
    # holding is least useful: the answer is in the log, and the caller cannot
    # read it while it is still waiting.
    for _ in $(seq 1 10); do
        if curl -sS -o /dev/null --max-time 2 "http://localhost:{{port}}/" 2>/dev/null; then
            echo "✓ {{port}} is answering on $after"
            up=1
            break
        fi
        sleep 2
    done

    if [ "${up:-0}" != "1" ]; then
        echo "→ still starting after 20s — it is detached and may yet come up."
        echo "  check:  curl -s -o /dev/null -w '%{http_code}' localhost:{{port}}"
        echo "  or why: tail -20 $log"
    fi

    # And the harness, because moving one without the other *is* the skew.
    #
    # A server and a harness on different commits speak different channel
    # contracts, and the symptom is `{:error, %{"reason" => "unmatched topic"}}`
    # on every stop — which reads as a connection problem and is not one.
    # Refreshing only the server does not risk that state, it creates it.
    #
    # Measured: this recipe moved :4000 to e34b11ca while the harness stayed on
    # 7d8cdfcd, and the next agent to write a file got its pre-tool-use hook
    # refused with exactly that error. The refusal named the commit range and
    # said to run `refresh-harness` — good diagnosis of a state that should not
    # have been reachable by running the documented command.
    #
    # Not `&&`: the harness is restarted whether or not the server came up
    # inside the poll window, because the server is detached and usually
    # arrives moments later. Skipping the harness on a slow boot would leave
    # exactly the mismatch this exists to prevent.
    echo
    just refresh-harness


# Restart the harness on :4004, from any worktree.
refresh-harness port="4004":
    #!/usr/bin/env bash
    set -euo pipefail

    # The other half of `just refresh`. A server and a harness on different
    # commits speak different channel contracts, and the symptom is
    # `{:error, %{"reason" => "unmatched topic"}}` on every stop — which reads
    # as a connection problem and is not one. `BootVersion.drift/0` names it in
    # the stop message; this is how it gets fixed.
    #
    # One harness serves every working copy: `Projects.ensure_started/1` picks
    # each one up from its first hook request, so restarting from any worktree
    # is safe and the others re-register on their next stop. Verified before
    # relying on it — the alternative, a harness that only served the directory
    # it started in, would strand every other agent.
    #
    # It does cost the other agents their in-flight sweeps, the same way a
    # server restart does (406f85db). Say so rather than doing it quietly.
    #
    # Launched from the main checkout, whatever directory you run this in.
    #
    # Two trees travel separately here and only one of them was ever in doubt.
    # *Analysis* follows the target: the harness shells into each working copy
    # and builds into that copy's `_build/analyzer`, so a worktree is always
    # analyzed by its own code. The harness's *own* code — `lib/cms_harness`,
    # the channel client, hook decisions — came from whichever checkout happened
    # to launch the process, and that is the whole of `c8a7f11d`.
    #
    # It matters because we edit `lib/cms_harness` while it is running. A
    # worktree that drifts past a channel-contract change takes every other
    # agent's hooks down with it — `{:error, %{"reason" => "unmatched topic"}}`
    # on every stop, across all three working copies at once — and the agent who
    # notices is left restarting a process rooted in somebody else's tree, whose
    # compile state they do not control. Measured on this machine: the harness
    # answering for three worktrees had its cwd in one of them.
    #
    # Pinned here, "is the harness stale" becomes "has main moved", which is one
    # question with one answer instead of one per checkout.
    #
    # Including while the harness itself is being changed. The workflow is push
    # to main, then restart — not run your worktree's copy and let everyone else
    # inherit it. Running it from a worktree is what makes this frothy: the
    # server has to be restarted for its own changes anyway, and a harness on a
    # third tree turns one restart into a three-way version negotiation nobody
    # is tracking. Merges are the only thing that should move the code that
    # serves everybody.
    main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

    # And pulls it, because otherwise the workflow above does not close. "Push
    # to main, restart, main serves it" needs the restart to actually fetch what
    # was pushed; without this the harness relaunches on whatever main happened
    # to be sitting at, which is a *quieter* version of the same staleness — the
    # drift check compares boot to checkout, and both would be equally old.
    #
    # Same refusal as `just refresh`, for the same reason: pulling over another
    # agent's uncommitted work in the shared checkout is worse than not
    # restarting.
    dirty="$(git -C "$main" status --porcelain --untracked-files=no --ignore-submodules=all)"
    if [ -n "$dirty" ]; then
        echo "✗ refusing: the main checkout has uncommitted work." >&2
        echo "$dirty" >&2
        echo "" >&2
        echo "  Another agent is probably mid-change there. Commit or stash it," >&2
        echo "  or restart by hand once it is clear." >&2
        exit 1
    fi

    before="$(git -C "$main" rev-parse --short HEAD)"
    git -C "$main" pull --ff-only
    after="$(git -C "$main" rev-parse --short HEAD)"
    echo "→ $before → $after"

    if [ -n "$(git -C "$main" diff --name-only "$before".."$after" -- mix.lock)" ]; then
        echo "→ mix.lock moved, fetching deps"
        ( cd "$main" && mix deps.get )
    else
        echo "→ mix.lock unchanged, skipping deps.get"
    fi

    # The same satisfiability check `refresh` carries, in dev_cli — the env the
    # harness actually boots in, and a different `_build` tree from dev.
    #
    # Without it this recipe killed the harness and could not start it again:
    #
    #     Unchecked dependencies for environment dev_cli:
    #     * req (Hex package)
    #       the dependency does not match the requirement "~> 0.7", got "0.5.17"
    #
    # mix.lock had not moved, so deps.get was skipped — and deps.get would not
    # have helped anyway. The stale copy is the compiled artifact under
    # `_build/dev_cli/lib/req`, which `deps.get` never touches and reports "all
    # dependencies have been fetched" over. `deps.compile` is what fixes it.
    #
    # The cost of not checking is not a failed recipe. It is every agent's hooks
    # down until somebody notices, because the harness is already dead by this
    # point.
    if ! ( cd "$main" && MIX_ENV=dev_cli mix loadpaths >/dev/null 2>&1 ); then
        echo "→ dev_cli deps do not satisfy mix.exs — fetching and recompiling"
        ( cd "$main" && MIX_ENV=dev_cli mix deps.get && MIX_ENV=dev_cli mix deps.compile )
    fi

    # And the app's own modules, which the deps check above does not cover.
    #
    # `_build/dev_cli` is a different tree from `_build/dev`, and only `dev`
    # refreshes on its own here — so the harness booted whatever dev_cli was
    # compiled the last time somebody thought to do it by hand. Measured
    # 2026-08-13: `_build/dev_cli/.../PostToolUse.beam` was two days stale while
    # `_build/dev` matched the source from that morning.
    #
    # The failure has no error in it, which is what makes it expensive. The hook
    # endpoints live on `CodeMySpecLocalWeb` — the app this env boots — so a new
    # hook or MCP tool simply is not there: `{}` from a hook that should answer,
    # "No such tool available" from a tool that is registered in source. QA
    # spent a pass concluding the feature did not exist, correctly, because on
    # that server it did not.
    #
    # Before the kill, deliberately: compiling while the harness is live risks
    # the lock, and compiling after it would delay every agent's hooks by the
    # length of a cold build.
    echo "→ compiling dev_cli (the env the harness boots; _build/dev_cli is its own tree)"
    ( cd "$main" && MIX_ENV=dev_cli mix compile )

    pid="$(lsof -nP -iTCP:{{port}} -sTCP:LISTEN -t || true)"

    if [ -n "$pid" ]; then
        echo "→ stopping harness $pid on {{port}}"
        echo "  in-flight analysis for every working copy dies with it"
        kill "$pid"
        for _ in $(seq 1 30); do
            lsof -nP -iTCP:{{port}} -sTCP:LISTEN -t >/dev/null 2>&1 || break
            sleep 1
        done
    else
        echo "→ nothing listening on {{port}}"
    fi

    log="$HOME/.codemyspec/harness_{{port}}.restart.log"

    # Rotated for the same reason as the server's, and with the same caveat: the
    # logfmt handlers cap themselves, raw stdout redirects do not. See `refresh`.
    mv -f "$log" "$log.1" 2>/dev/null || true

    # `exec </dev/null >"$log" 2>&1` in the subshell, not just on the child.
    # Starting a beam leaves `epmd` behind, daemonized, holding whatever
    # descriptors it inherited — so a caller waiting for its pipe to close waits
    # forever on a recipe that has already exited. Redirecting the child alone
    # is not enough; the descendant already has copies.
    # `cd` on its own line, not `cd && exec`: with `&&` a failed cd skips only
    # the redirect, and `nohup just harness &` after the `;` would still launch —
    # from the wrong tree, which is the exact thing this recipe now exists to
    # prevent. Bare, `set -e` aborts the subshell instead.
    ( cd "$main"; exec </dev/null >"$log" 2>&1; nohup just harness & )
    echo "→ starting from $main, logging to $log"

    for _ in $(seq 1 90); do
        if lsof -nP -iTCP:{{port}} -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo "✓ harness is listening on {{port}}"
            echo "  working copies re-register on their next hook"
            echo
            echo "  If this restart shipped a NEW MCP tool, every already-running"
            echo "  agent still has the old tool list and will get \"No such tool"
            echo "  available\" until it reconnects (/mcp in Claude Code). The"
            echo "  server is not the reason; the client caches the list. b2d9c616."
            exit 0
        fi
        sleep 2
    done

    echo "✗ harness did not come up in 180s — see $log" >&2
    exit 1

cli *args:
    MIX_ENV=dev_cli iex -S mix run --no-halt {{args}}

# Make sure `.code_my_spec` is the real submodule and not an empty mount point
#
# `git worktree add` does not populate submodules, and nothing downstream
# notices. The harness scans the working copy and the requirement graph is
# computed from what it finds, so an uninitialised `.code_my_spec` does not read
# as a missing checkout — it reads as a project with no personas, no
# architecture and no specs. Measured in the phx-new-generator worktree: 31
# files against the submodule's 3,346, and `personas_complete` reported
# unsatisfied while all five personas sat fully researched in the main checkout.
# The agent is then told to redo work that already exists.
#
# Worse when partial. Tools write into the mount point, so it fills up enough to
# look real, and `git submodule update --init` then refuses rather than
# repairing it. That case cannot be fixed silently — untracked files would be
# overwritten — so it is reported instead, which is the half `6b69c7c6` said was
# missing: nothing said so.
_submodules:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f .gitmodules ] || exit 0
    git submodule status 2>/dev/null | grep -q '^-' || exit 0
    echo "→ .code_my_spec submodule is not initialised — populating it." >&2
    if ! git submodule update --init --recursive 2>/dev/null; then
      echo                                                                     >&2
      echo "Could not initialise the submodule: files are already in its"      >&2
      echo "mount point and git will not overwrite them."                      >&2
      echo                                                                     >&2
      echo "This checkout is working against a PARTIAL .code_my_spec. The"     >&2
      echo "requirement graph is computed from what the harness can see, so"   >&2
      echo "work that exists elsewhere reads as work never done — you will be" >&2
      echo "asked to redo personas, specs and architecture that are already"   >&2
      echo "written."                                                          >&2
      echo                                                                     >&2
      echo "Move the strays aside, then run: git submodule update --init"      >&2
      echo "Check first whether any of them exist ONLY here."                  >&2
      echo                                                                     >&2
      # Warn, do not block. Every existing worktree on this machine is already
      # in this state, and a dependency that refuses to start the harness would
      # take three agents offline to report a diagnosis. The complaint in
      # 6b69c7c6 is that nothing said so — this says so.
      echo "Continuing anyway; the harness still runs against what is here."   >&2
    fi

# Run the light harness on 4004 (no local DB — reports to the dev server)
harness port="4004" server="http://localhost:4000": _submodules
    #!/usr/bin/env bash
    set -euo pipefail
    # Serves hooks AND MCP on 4004 — the port the in-repo plugin points at,
    # which the packager rewrites to 4003 on release. So this and
    # `just claude-dev` talk to each other while the installed `cms` on 4003
    # keeps serving every other session untouched.
    #
    # The credential is a project deploy key, traded for a short-lived token at
    # /api/sprite/token. envs/.env is gitignored and already this repo's place
    # for secrets — but it is NOT enough on its own to reach the harness.
    # `config/runtime.exs` loads it with Dotenvy, whose default side effect
    # writes to the *process dictionary* for `env!/2`, not to the OS
    # environment. `CmsHarness.Config` reads `System.get_env`, so the recipe has
    # to export the values itself. Assuming otherwise cost a boot that came up
    # cleanly and refused every hook with "no credential".
    if [ -f envs/.env ]; then
      while IFS='=' read -r key value; do
        # An exported value wins, so a one-off `CMS_DEPLOY_KEY=… just harness`
        # overrides the file rather than being silently ignored.
        [ -n "${!key:-}" ] || export "$key=$value"
      done < <(grep -E '^CMS_(DEPLOY_KEY|TOKEN)=' envs/.env)
    fi
    if [ -z "${CMS_DEPLOY_KEY:-}" ] && [ -z "${CMS_TOKEN:-}" ]; then
      echo "No credential. Copy the project's deploy key from"                >&2
      echo "  {{server}}/app/projects/<project-id>/edit"                      >&2
      echo "and put CMS_DEPLOY_KEY=... in envs/.env (or export it)."          >&2
      echo                                                                    >&2
      echo "Generate only fills the field — Save is what stores the hash, so" >&2
      echo "a key copied without saving matches nothing."                     >&2
      exit 1
    fi
    # `elixir -S mix`, not `mix`: a bare `mix` in a worktree resolves against
    # the main checkout and would run the wrong tree's code.
    CMS_HARNESS=1 CMS_HARNESS_PORT={{port}} CMS_SERVER_URL={{server}} \
      MIX_ENV=dev_cli elixir -S mix run --no-halt

# Start Claude Code against this checkout's own plugin — pair with `just harness`
claude-dev *args: _submodules
    #!/usr/bin/env bash
    set -euo pipefail
    # Against `.claude/plugin-dev`, not `plugins/claude`. The tracked plugin is
    # what the packager ships, so it carries no harness id — pointed at a
    # harness it gets refused with "this hook did not say which working copy it
    # is about", which is correct and reads like a bug. The generated one has
    # this checkout's id in every hook URL and in the MCP URL.
    #
    # Onboarding is idempotent and mints an id from the server if this checkout
    # has none, so a fresh worktree works on the first run.
    PLUGIN="{{justfile_directory()}}/.claude/plugin-dev"
    if [ ! -d "$PLUGIN" ]; then
      echo "No generated plugin yet — onboarding this checkout."
      # Same export `harness` does, for the same reason: minting an id is a
      # call to the server, `CmsHarness.Config` reads `System.get_env`, and
      # Dotenvy's default side effect writes the *process dictionary* rather
      # than the OS environment. Without this a fresh worktree fails onboarding
      # with `{:error, :no_credential}` while envs/.env sits right there.
      if [ -f envs/.env ]; then
        while IFS='=' read -r key value; do
          [ -n "${!key:-}" ] || export "$key=$value"
        done < <(grep -E '^CMS_(DEPLOY_KEY|TOKEN)=' envs/.env)
      fi
      # `elixir -S mix`, not bare `mix`: in a worktree the latter resolves
      # against the main checkout and onboards the wrong tree.
      elixir -S mix cms.harness.onboard
    fi
    # Session-scoped: --plugin-dir applies to this invocation only, so every
    # other Claude session keeps the marketplace plugin and the cms on 4003.
    claude --plugin-dir "$PLUGIN" {{args}}

# Run tests
test *args:
    mix test {{args}}

# Run a specific test file/line
test-file file:
    mix test {{file}} --trace

# Run the analyzer tests — the ones that need real projects on disk.
#
# Two kinds, excluded from `just test` for the same reason. The
# `code_my_spec_test_repos` ones rsync a copy out of a directory every worktree
# reaches by symlink, so two agents running suites collided there — which is
# where the `** (EXIT …) killed` findings came from. `cms_harness/analysis_test`
# builds its own temp projects instead, but spawns seven real `mix` subprocess
# trees to do it and carries the one measured intermittent failure of the class
# (75b35ac2 — full-suite only, never standalone, still untraced).
#
# Everything else reads the committed recordings in
# `test/fixtures/analyzer_output/`.
#
# Run this when you change an analyzer, and after `mix cms.test_fixtures`.
# Needs the fixture repos; `mix cms.test_fixtures` clones them.
test-analyzer *args:
    MIX_ENV=test mix test --only analyzer {{args}}

# Record the analyzer fixtures the suite reads. Clones the fixture repos if
# they are missing. Commit what it changes.
test-fixtures:
    MIX_ENV=test mix cms.test_fixtures

# Setup: deps + db
setup:
    mix deps.get && mix ecto.setup

# Reset the dev database
reset-db:
    mix ecto.reset

# Compile with warnings as errors
check:
    mix compile --warnings-as-errors

# Build CLI release (Burrito binary)
build-cli:
    MIX_ENV=prod_cli mix release code_my_spec_cli

# Dry-run the plugin packager — lays out release/codemyspec-extension/ locally for inspection
package-plugin:
    MIX_ENV=dev_cli mix cms.package_plugin
    @echo
    @echo "Diff vs source: diff -r plugins/claude release/codemyspec-extension/plugins/codemyspec"
    @echo "Sanity check:   grep -rn 4004 release/codemyspec-extension   # should be empty"

# Bump plugin.json + mix.exs to VERSION and stage them — then commit + push, then `just release`
bump VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! echo "{{VERSION}}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "Bad version: {{VERSION}} (want N.N.N)" >&2
      exit 1
    fi
    sed -i.bak -E 's/"version": "[0-9.]+"/"version": "{{VERSION}}"/' plugins/claude/.claude-plugin/plugin.json
    sed -i.bak -E 's/"version": "[0-9.]+"/"version": "{{VERSION}}"/' plugins/codex/.codex-plugin/plugin.json
    sed -i.bak -E 's/version: "[0-9.]+",/version: "{{VERSION}}",/' mix.exs
    rm -f plugins/claude/.claude-plugin/plugin.json.bak plugins/codex/.codex-plugin/plugin.json.bak mix.exs.bak
    git add plugins/claude/.claude-plugin/plugin.json plugins/codex/.codex-plugin/plugin.json mix.exs
    echo
    echo "Bumped to {{VERSION}}, staged. Commit (bundling other changes if you like), push, then \`just release\`."

# One-shot bump + commit + push + tag — wires both files together so the marketplace manifest can't drift from mix.exs
publish VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! echo "{{VERSION}}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "Bad version: {{VERSION}} (want N.N.N)" >&2
      exit 1
    fi
    if [ -n "$(git status --porcelain plugins/claude/.claude-plugin/plugin.json mix.exs)" ]; then
      echo "plugin.json or mix.exs already has uncommitted changes — commit or reset first" >&2
      exit 1
    fi

    # Releases go from main, and this has to say so before it writes anything.
    #
    # `git push origin HEAD` pushes to a remote branch of the *same name*, so
    # run from a worktree on `light-harness` it created `origin/light-harness`
    # and left main without the version bump. `release` then refused, naming
    # origin/main — which was true and unrelated to what had just gone wrong.
    # Two steps disagreeing about which branch a release lives on.
    git fetch origin main --quiet
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
      echo "✗ HEAD is not at origin/main — a release is a commit on main." >&2
      echo >&2
      git log --oneline --left-right HEAD...origin/main >&2
      echo >&2
      echo "  From a worktree: rebase onto origin/main first, or run this from" >&2
      echo "  the main checkout. The tag has to point at a commit main has." >&2
      exit 1
    fi

    just bump {{VERSION}}
    git commit -m "Release v{{VERSION}}"
    git push origin HEAD:main
    just release

# Tag HEAD with vN.N.N from plugin.json and push the tag — triggers the marketplace release CI
release:
    #!/usr/bin/env bash
    set -euo pipefail

    plugin_version=$(jq -r .version plugins/claude/.claude-plugin/plugin.json)
    mix_version=$(grep -E '^      version:' mix.exs | sed -E 's/.*"([0-9.]+)".*/\1/')

    if [ "$plugin_version" != "$mix_version" ]; then
      echo "Version mismatch: plugin.json=$plugin_version mix.exs=$mix_version" >&2
      exit 1
    fi

    tag="v$plugin_version"

    if git rev-parse "$tag" >/dev/null 2>&1; then
      echo "Tag $tag already exists locally" >&2
      exit 1
    fi

    if [ -n "$(git status --porcelain plugins/claude/.claude-plugin/plugin.json mix.exs)" ]; then
      echo "plugin.json or mix.exs has uncommitted changes — commit first" >&2
      exit 1
    fi

    # `origin/main` by name, not `@{u}`. The upstream of the current branch is
    # whatever that branch tracks — on a worktree branch that is often itself —
    # so the check could pass against a branch main has never seen while the
    # message claimed it had compared against main. A tag is permanent and
    # points at one commit; the check that guards it should name the same ref
    # the message does.
    git fetch origin main --quiet
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
      echo "HEAD is not at origin/main. Push first:" >&2
      git log --oneline --left-right HEAD...origin/main >&2
      exit 1
    fi

    git tag "$tag" HEAD
    git push origin "$tag"
    echo
    echo "Tagged $tag and pushed. CI:"
    echo "  https://github.com/Code-My-Spec/code_my_spec/actions/workflows/release-extension.yml"
    echo "Marketplace:"
    echo "  https://github.com/Code-My-Spec/plugins"

# Push this worktree's HEAD to origin/main, then make it live.
#
# `git push origin main` from a worktree pushes the local `main` *ref*, which in
# a worktree is whatever main pointed at when the tree was made — not HEAD. It
# reports "Everything up-to-date" and exits 0, so the commit never leaves the
# machine and nothing says so. That happened; it surfaced only because the
# `sync-main` that followed said "already current".
#
# `HEAD:main` is the form that means what you meant. This wraps it so the
# question does not come up again, and runs sync-main after so pushed and live
# are one step rather than two with a silent gap between them.
ship:
    #!/usr/bin/env bash
    set -euo pipefail

    branch=$(git rev-parse --abbrev-ref HEAD)
    ahead=$(git rev-list --count origin/main..HEAD)

    if [ "$ahead" = "0" ]; then
      echo "nothing to push — HEAD is not ahead of origin/main"
      exit 0
    fi

    echo "pushing $ahead commit(s) from '$branch' to origin/main:"
    git log --oneline origin/main..HEAD | sed 's/^/  /'
    git push origin HEAD:main
    just sync-main

# Fast-forward the main checkout to origin/main.
#
# The dev server on :4000 runs from the main checkout, not from a worktree, so
# nothing pushed from a worktree is live until that tree pulls. Twice in one
# session a fix sat inert for an hour because of it, and both times it read as
# the fix not working rather than the fix not being loaded.
#
# Fast-forward only, and refuses a dirty tree. That checkout is where merges get
# done by hand, so anything else there is someone's work in progress — this is
# for picking up what is already on origin, never for resolving anything.
sync-main root="/Users/johndavenport/Documents/github/code_my_spec":
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{root}}"

    if [ ! -d "$root/.git" ]; then
      echo "not a git checkout: $root" >&2
      exit 1
    fi

    branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "main" ]; then
      echo "$root is on '$branch', not main — leaving it alone." >&2
      exit 1
    fi

    # `--ignore-submodules=all` because `.code_my_spec`'s pointer is chronically
    # dirty in that checkout and belongs to nobody. A fast-forward of the
    # superproject does not touch submodule contents, so it is not a reason to
    # refuse — and without this the recipe never runs at all, which is how a
    # safety check becomes a thing people work around.
    if [ -n "$(git -C "$root" status --porcelain --untracked-files=no --ignore-submodules=all)" ]; then
      echo "$root has uncommitted changes; refusing to touch it:" >&2
      git -C "$root" status --short --untracked-files=no --ignore-submodules=all >&2
      exit 1
    fi

    before=$(git -C "$root" rev-parse --short HEAD)
    git -C "$root" fetch --quiet origin main
    git -C "$root" merge --ff-only --quiet FETCH_HEAD
    after=$(git -C "$root" rev-parse --short HEAD)

    if [ "$before" = "$after" ]; then
      echo "already current at $after"
    else
      echo "$before -> $after"
      git -C "$root" log --oneline "$before..$after" | sed 's/^/  /'
      echo
      echo "Phoenix reloads changed modules on the next request. A new dependency"
      echo "or a config change still needs the server restarted."
    fi
