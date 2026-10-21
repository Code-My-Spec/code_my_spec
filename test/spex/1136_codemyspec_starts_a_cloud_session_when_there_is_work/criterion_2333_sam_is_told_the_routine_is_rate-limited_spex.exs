defmodule CodeMySpecSpex.Story1136.Criterion2333Spex do
  @moduledoc """
  Story 1136 — CodeMySpec starts a cloud session when there is work.
  Criterion 2333 — Sam is told the routine is rate-limited.

  The refusal is `429` with `{"type": "error", "error": {"type": "rate_limit_error", …}}`
  and a `Retry-After` header; there is no reset time in the body, so "when he can
  try again" is read from the header (seconds or an HTTP date).
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

  spex "A rate-limited start says so and is not retried", criterion: 2333 do
    scenario "Claude refuses the start" do
      given_ "Claude refuses the start because the routine's hourly limit is reached", context do
        test_pid = self()

        Req.Test.stub(CodeMySpec.Devices.RoutineFire, fn conn ->
          send(test_pid, :fire_attempt)

          conn
          |> Plug.Conn.put_resp_header("retry-after", "1800")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{
            "type" => "error",
            "error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}
          })
        end)

        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        add_fire_token(live, box.id, @routine, @fire_token)
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "Sam presses Start", context do
        {:ok, Map.put(context, :html, press_start(context.live, context.box.id))}
      end

      then_ "he is told it was rate-limited and when he can try again", context do
        assert context.html =~ ~r/rate.limited/i
        assert context.html =~ ~r/30 minutes|try again/i
        {:ok, context}
      end

      then_ "and CodeMySpec does not retry by itself", context do
        assert_receive :fire_attempt
        refute_receive :fire_attempt, 300
        {:ok, context}
      end
    end
  end
end
