# List available recipes
default:
    @just --list

# Run the web app (Postgres, port 4000)
server:
    iex -S mix phx.server

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

    dirty="$(git -C "$main" status --porcelain)"
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

    # The lock moves often enough that skipping this turns into "Unchecked
    # dependencies" on the next mix invocation, which several analyzers report
    # as findings rather than as an environment problem.
    ( cd "$main" && mix deps.get )

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
    ( cd "$main" && nohup mix phx.server >>"$log" 2>&1 & )
    echo "→ starting, logging to $log"

    for _ in $(seq 1 90); do
        if curl -sS -o /dev/null --max-time 2 "http://localhost:{{port}}/" 2>/dev/null; then
            echo "✓ {{port}} is answering on $after"
            echo "  confirm with: grep '\[Boot\] serving' ~/.codemyspec/web.log | tail -1"
            exit 0
        fi
        sleep 2
    done

    echo "✗ {{port}} did not come up in 180s — see $log" >&2
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
    just bump {{VERSION}}
    git commit -m "Release v{{VERSION}}"
    git push origin HEAD
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

    if [ "$(git rev-parse HEAD)" != "$(git rev-parse @{u})" ]; then
      echo "HEAD is not at origin/main. Push first:" >&2
      git log --oneline --left-right HEAD...@{u} >&2
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
