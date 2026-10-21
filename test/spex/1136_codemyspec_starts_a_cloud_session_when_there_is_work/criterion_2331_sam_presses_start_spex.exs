defmodule CodeMySpecSpex.Story1136.Criterion2331Spex do
  @moduledoc """
  Story 1136 — CodeMySpec starts a cloud session when there is work.
  Criterion 2331 — Sam presses Start.

  The fire call is `POST /v1/claude_code/routines/<routine id>/fire` with the
  per-routine token as the bearer credential; a 200 answers
  `{"type": "routine_fire", "claude_code_session_id": …, "claude_code_session_url": …}`
  once the session is created. The call is answered by a stub (never the live
  endpoint).
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  @routine "trig_01ABCDEF"
  @fire_token "sk-ant-oat01-fire-token-1"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Start fires the routine and the box connects", criterion: 2331 do
    scenario "Sam presses Start on a down box" do
      given_ "Sam's cloud box 'cloud-1' has a fire token and is down", context do
        stub_routine_fire(:ok)

        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        add_fire_token(live, box.id, @routine, @fire_token)
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "he presses Start on Dev boxes", context do
        {:ok, Map.put(context, :html, press_start(context.live, context.box.id))}
      end

      then_ "the routine is fired with its own token", context do
        {path, authorization} = assert_fired()
        assert path == "/v1/claude_code/routines/trig_01ABCDEF/fire"
        assert authorization == ["Bearer " <> @fire_token]

        {:ok, context}
      end

      then_ "a session starts, linked from the box", context do
        assert has_element?(
                 context.live,
                 "[data-test='session-url'][href='https://claude.ai/code/session_01XYZ']"
               )

        {:ok, context}
      end

      then_ "and 'cloud-1' connects", context do
        assert exchanged(context.box.token)["device_id"] == context.box.id

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
