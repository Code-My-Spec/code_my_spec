defmodule CodeMySpecSpex.Story1140.Criterion2358Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2358 — Restarting the container keeps the box.

  The container's files survive a stop and start, so the same box signs in with
  the same token and does not repeat setup it finished (the record of the run is
  read, as in criterion 2319).
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A restarted container is the same box and does not set up again", criterion: 2358 do
    scenario "Sam stops and starts the container" do
      given_ "Sam's Docker box 'docker-1' is connected", context do
        Fixtures.install_workspace_runner(healthy?: true, serving: :serving)
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "docker-1", "docker")
        _ = exchanged(box.token)
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "its container is stopped and started again", context do
        Fixtures.put_workspace_healthy(false)
        Fixtures.put_workspace_healthy(true)
        {:ok, Map.put(context, :again, exchanged(context.box.token))}
      end

      then_ "it reconnects as 'docker-1'", context do
        assert context.again["device_id"] == context.box.id
        {:ok, context}
      end

      then_ "and does not repeat setup it finished", context do
        assert length(Fixtures.workspace_start_calls()) == 1,
               "restarting the container ran the box's setup and start again"

        {:ok, context}
      end
    end
  end
end
