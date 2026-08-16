#!/usr/bin/env bash
#
# The generated site the provisioning spex record against, on :4100.
#
# Story 972's publish criteria and story 973's widget criteria both end by
# fetching a real page from a real application — a trigger that was accepted, a
# widget that is on the page. For months that application lived in a session
# scratchpad with no commits, so the criteria were green on one machine and
# nowhere else, and nothing said so.
#
# This builds it from the committed checkout instead. It is needed only while
# recording (SPEX_CASSETTE_MODE=record); on replay the cassettes answer and
# nothing here has to be running.
#
#   docker/fleet/site.sh          # prepare and serve on :4100
#   docker/fleet/site.sh prepare  # wire it, don't serve
#
set -euo pipefail

SITE_SRC="${CMS_FLEET_SITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/code_my_spec_test_repos/fleet_site}"
SITE_RUN="${CMS_FLEET_SITE_RUN:-${SITE_SRC}_run}"
PORT="${CMS_FLEET_SITE_PORT:-4100}"
DEPLOY_KEY="${CMS_FLEET_DEPLOY_KEY:-dk_fleet_spex}"

# The source checkout stays pristine: the spex records its own generator run
# against it, and a checkout that already has the widget would meet the
# overwrite prompt and hang the suite on stdin.
if [ ! -f "$SITE_SRC/mix.exs" ]; then
  echo "No application at $SITE_SRC — set CMS_FLEET_SITE." >&2
  exit 1
fi

app=$(grep -m1 -oE 'app: :[a-z_0-9]+' "$SITE_SRC/mix.exs" | cut -d: -f3)
base=$(echo "$app" | awk -F_ '{for(i=1;i<=NF;i++) printf toupper(substr($i,1,1)) substr($i,2)}')

prepare() {
  echo "==> preparing $SITE_RUN (app: $app, module: $base)"
  rm -rf "$SITE_RUN"
  # --exclude .git: this is a derived tree, not a checkout. Keeping the git
  # directory invites committing into it by accident and then losing the work
  # on the next prepare.
  rsync -a --exclude .git --exclude _build --exclude deps "$SITE_SRC/" "$SITE_RUN/"

  cd "$SITE_RUN"
  # Before the generator, not after: it is a task supplied by a dependency, so
  # `mix` refuses to load the project at all until the deps are there — and it
  # says "the task could not be found", which reads as the generator being
  # missing rather than the tree being empty.
  mix deps.get >/dev/null
  mix cms_gen.support_widget </dev/null >/dev/null

  # 1. slipstream, which the widget client rides.
  grep -q '{:slipstream' mix.exs ||
    perl -0pi -e 's/(\{:bandit, "~> 1\.5"\},)/$1\n      {:slipstream, "~> 1.1"},/' mix.exs

  # 2. registry + supervisor, before the Endpoint.
  app_file="lib/${app}_web/application.ex"
  grep -q 'WidgetRegistry' "$app_file" ||
    perl -0pi -e "s/(\n\s*${base}Web\.Endpoint\n)/\n      {Registry, keys: :unique, name: ${base}.CodeMySpec.WidgetRegistry},\n      {DynamicSupervisor, strategy: :one_for_one, name: ${base}.CodeMySpec.WidgetSupervisor},\$1/" "$app_file"

  # 3. render it, for every visitor — not only signed-in users. Someone who
  #    bounced off the product is exactly who has something to say.
  layout="lib/${app}_web/components/layouts/root.html.heex"
  grep -q 'SupportWidgetLive' "$layout" ||
    perl -0pi -e "s|(\n\s*</body>)|\n    {live_render(\@conn, ${base}Web.SupportWidgetLive, id: \"codemyspec-support\", sticky: true)}\$1|" "$layout"

  # 4. point it at the local CodeMySpec, with the fleet's deploy key.
  grep -q 'codemyspec_widget_url' config/dev.exs ||
    cat >>config/dev.exs <<EOF

# Fleet recording: the widget talks to the local CodeMySpec, not production.
config :$app,
  codemyspec_widget_url: System.get_env("CODEMYSPEC_WIDGET_URL") || "ws://127.0.0.1:4000/widget",
  deploy_key: System.get_env("DEPLOY_KEY") || "$DEPLOY_KEY"
EOF

  mix deps.get >/dev/null
  mix compile
  echo "==> prepared"
}

serve() {
  cd "$SITE_RUN"
  echo "==> serving $app on http://127.0.0.1:$PORT"
  # DEPLOY_KEY in the environment, not only in dev.exs. The generated app's
  # `config/runtime.exs` ends with
  #
  #     config :$app, :deploy_key, System.get_env("DEPLOY_KEY")
  #
  # unconditionally, and runtime.exs is evaluated after dev.exs — so with the
  # variable unset it writes `nil` straight over the default `prepare` appends,
  # and the config file says the right thing while the running app has nothing.
  #
  # `POST /api/content/pull` then answers 500 "Deploy key not configured on
  # server", which is what the content step's render proof gets back — so a
  # criterion about proving a post rendered fails as though the product never
  # proves renders. Cost a 554s live recording to find, twice.
  PORT="$PORT" DEPLOY_KEY="$DEPLOY_KEY" mix phx.server
}

case "${1:-serve}" in
prepare) prepare ;;
serve)
  prepare
  serve
  ;;
*)
  echo "usage: site.sh [prepare|serve]" >&2
  exit 1
  ;;
esac
