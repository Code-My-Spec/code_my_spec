defmodule CodeMySpecSpex.Story984.Criterion8174Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8174 — A streamed response reaches the agent as it is
  produced.

  Recording must not turn a streamed turn into a buffered one. If the
  recorder waits for the whole response before passing it on, every
  turn of every run gets slower and the agent's behaviour changes —
  so the response the agent receives has to still be a stream, and
  what was recorded has to match what the agent actually got.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Streaming survives being recorded" do
    scenario "A streamed response reaches the agent as it is produced" do
      when_ "the agent takes a turn whose response is streamed", context do
        response =
          with_recorder_cassette("sprite_streamed_turn", fn ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
              "model" => "claude-opus-5",
              "max_tokens" => 256,
              "stream" => true,
              "messages" => [%{"role" => "user", "content" => "summarize the run"}]
            })
          end)

        {:ok, Map.put(context, :turn, response)}
      end

      then_ "the agent receives a stream rather than one buffered body", context do
        content_type =
          context.turn
          |> Plug.Conn.get_resp_header("content-type")
          |> List.first()

        assert content_type =~ "text/event-stream",
               "expected the recorder to pass the response through as a stream, got: #{inspect(content_type)}"

        assert context.turn.resp_body =~ "content_block_delta",
               "expected the streamed events to reach the agent intact"

        {:ok, context}
      end

      and_ "what was recorded matches what the agent received", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "summarize the run",
               "expected the recorded turn to carry the request the agent sent"

        assert html =~ "the run finished clean",
               "expected the recorded response to match the text the agent was streamed"

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
