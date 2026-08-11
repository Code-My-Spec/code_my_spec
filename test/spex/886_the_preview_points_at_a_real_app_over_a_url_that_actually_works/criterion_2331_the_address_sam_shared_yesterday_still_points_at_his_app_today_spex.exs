defmodule CodeMySpecSpex.Story886.Criterion2331Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2331 — The address Sam shared yesterday still points at his app
  today.

  Rule: the preview lives at an address Sam can send to someone else.

  A preview address is worth having only if it survives being written down.
  Sam sends it to a colleague on Tuesday; the container is rebuilt on
  Wednesday and comes up on a different published port; the link has to still
  work on Thursday. That rules out addressing anything about the running
  instance — the container name, the port, a session id — and leaves the
  project, which is the one thing that does not change.

  The container moving is not an edge case. It happens on every rebuild, and
  a rebuild is the normal consequence of Sam asking for a change.

  Surface: `CodeMySpecWeb.Plugs.PreviewProxy` and the address it is reached
  at.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A preview address is worth writing down" do
    scenario "The address Sam shared yesterday still points at his app today" do
      given_ "Sam's app is running and he sends someone the address", context do
        host =
          Fixtures.preview_app(context.scope, context.project.id,
            body: "<h1>Widget Tracker</h1><p>first build</p>"
          )

        shared = Phoenix.ConnTest.build_conn() |> Map.put(:host, host) |> get("/")

        assert shared.resp_body =~ "first build",
               "the address did not work when he shared it, so nothing after this matters"

        {:ok, Map.put(context, :shared_address, host)}
      end

      when_ "the app is rebuilt and comes up somewhere else entirely", context do
        # A new container on a new port, which is what a rebuild produces.
        # `preview_app/3` replaces the workspace row for this project, so
        # nothing about the old instance survives except the project it
        # belonged to.
        rebuilt =
          Fixtures.preview_app(context.scope, context.project.id,
            body: "<h1>Widget Tracker</h1><p>second build</p>"
          )

        {:ok, Map.put(context, :rebuilt_address, rebuilt)}
      end

      then_ "the address he shared is unchanged", context do
        assert context.rebuilt_address == context.shared_address,
               "the preview address moved with the container, so every link Sam has " <>
                 "already sent is now dead"

        {:ok, context}
      end

      then_ "and it now serves the rebuilt app", context do
        answer =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.shared_address)
          |> get("/")

        assert answer.status == 200,
               "the shared address stopped working after a rebuild, got " <>
                 "#{answer.status}: #{answer.resp_body}"

        assert answer.resp_body =~ "second build",
               "the address survived but still points at the old container"

        {:ok, context}
      end

      then_ "and it never needed Sam to be logged in", context do
        # He sent it to someone who has no account. An address that only works
        # for its owner is not something you can send anybody.
        stranger =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.shared_address)
          |> get("/")

        assert stranger.status == 200,
               "a preview link required an account, so Sam cannot show anyone his app"

        {:ok, context}
      end
    end
  end
end
