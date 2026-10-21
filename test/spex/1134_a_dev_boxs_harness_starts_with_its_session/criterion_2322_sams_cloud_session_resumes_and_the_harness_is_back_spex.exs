defmodule CodeMySpecSpex.Story1134.Criterion2322Spex do
  @moduledoc """
  Story 1134 — A dev box's harness starts with its session.
  Criterion 2322 — Sam's cloud session resumes and the harness is back.

  There is no Claude Code cloud VM to pause in a spec. What Sam is given is the
  setup script the environment runs, which installs the SessionStart hook that
  brings the harness up, so this reads the script the Dev boxes page showed him
  (the same surface story 1133 reads) and drives the server half for real: the
  box signing in again, and the channel join.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A resumed session brings the harness back", criterion: 2322 do
    scenario "the session paused and the harness was killed" do
      given_ "Sam's Claude cloud session paused and its harness was killed", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        _first = exchanged(box.token)
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "the session resumes", context do
        script = shown_setup_script(context.live)
        again = exchanged(context.box.token)
        {:ok, Map.merge(context, %{script: script, again: again})}
      end

      then_ "the session-start hook starts the harness", context do
        assert context.script =~ "SessionStart",
               "the setup script installs no SessionStart hook:\n\n#{context.script}"

        assert context.script =~ ~r/cms-cloud-session/

        assert context.script =~ ~r/mix run --no-halt|cms harness/,
               "the hook does not start the harness"

        {:ok, context}
      end

      then_ "the box shows as connected again", context do
        assert context.again["device_id"] == context.box.id

        eventually(fn ->
          assert context.live
                 |> element(
                   "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-status']"
                 )
                 |> render() =~ "Connected"
        end)

        {:ok, context}
      end
    end
  end
end
