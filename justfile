# List available recipes
default:
    @just --list

# Run the web app (Postgres, port 4000)
server:
    iex -S mix phx.server

cli *args:
    MIX_ENV=dev_cli iex -S mix run --no-halt {{args}}

# Run the light harness on 4004 (no local DB — reports to the dev server)
harness port="4004" server="http://localhost:4000":
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

# Start Claude Code against the in-repo plugin — pair with `just harness`
claude-dev *args:
    # Session-scoped: --plugin-dir applies to this invocation only, so every
    # other Claude session keeps the marketplace plugin and the cms on 4003.
    claude --plugin-dir {{justfile_directory()}}/plugins/claude {{args}}

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
