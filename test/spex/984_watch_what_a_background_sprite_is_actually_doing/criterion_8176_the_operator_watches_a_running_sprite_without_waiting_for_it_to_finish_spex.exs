defmodule CodeMySpecSpex.Story984.Criterion8176Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8176 — The operator watches a running sprite without
  waiting for it to finish.

  A record you can only read after the run ends is a post-mortem, not
  observation. The operator opens the conversation part-way through and
  sees the turns taken so far; further turns arrive on the open page
  without a reload.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A running sprite can be watched live" do
    scenario "The operator watches a running sprite without waiting for it to finish" do
      given_ "the sprite is part-way through a run", context do
        with_recorder_cassette("sprite_first_turn", fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
            "model" => "claude-opus-5",
            "max_tokens" => 64,
            "messages" => [%{"role" => "user", "content" => "start the first requirement"}]
          })
        end)

        {:ok, context}
      end

      when_ "the operator opens the conversation while it is still running", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "start the first requirement",
               "expected the turns taken so far to be visible mid-run"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "a further turn appears without reloading the page", context do
        with_recorder_cassette("sprite_second_turn", fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
            "model" => "claude-opus-5",
            "max_tokens" => 64,
            "messages" => [%{"role" => "user", "content" => "move to the next requirement"}]
          })
        end)

        assert render(context.view) =~ "move to the next requirement",
               "expected the new turn to arrive on the already-open conversation"

        {:ok, context}
      end
    end
  end

  @cassette_opts [cassette_dir: "test/cassettes/anthropic"]

  # The cassette hands back a plug; the recorder picks it up from its own
  # app config, the same seam Ads uses. Restored afterwards so one spec
  # cannot leak a stubbed upstream into the next.
  defp with_recorder_cassette(name, fun) do
    with_cassette name, @cassette_opts, fn plug ->
      original = Application.get_env(:code_my_spec, ConversationRecorder, [])

      Application.put_env(
        :code_my_spec,
        ConversationRecorder,
        Keyword.put(original, :plug, plug)
      )

      try do
        fun.()
      after
        Application.put_env(:code_my_spec, ConversationRecorder, original)
      end
    end
  end

end
