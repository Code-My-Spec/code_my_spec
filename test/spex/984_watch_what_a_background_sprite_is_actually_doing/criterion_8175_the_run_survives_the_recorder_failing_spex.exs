defmodule CodeMySpecSpex.Story984.Criterion8175Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8175 — The run survives the recorder failing.

  Observability must never be able to take down the thing it observes.
  With the conversation store unwritable, the agent's turn still has to
  complete and the run has to carry on — and the operator must not be
  shown a conversation that looks complete when turns are missing from
  it.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A broken recorder does not break the run" do
    scenario "The run survives the recorder failing" do
      given_ "the conversation store cannot be written to", context do
        {:ok, Map.put(context, :conversation_store, :unwritable)}
      end

      when_ "the agent takes a turn", context do
        response =
          with_recorder_cassette("sprite_turn_with_broken_recorder", fn ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("x-recorder-store", "unwritable")
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
              "model" => "claude-opus-5",
              "max_tokens" => 64,
              "messages" => [%{"role" => "user", "content" => "keep working"}]
            })
          end)

        {:ok, Map.put(context, :turn, response)}
      end

      then_ "the turn still completes normally for the agent", context do
        assert context.turn.status == 200,
               "a failed recorder must not surface to the agent as a failed turn"

        assert context.turn.resp_body != "",
               "the agent must still receive the model's response"

        {:ok, context}
      end

      and_ "the operator is not shown a conversation that looks complete", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='recording-gap']"),
               "expected the conversation to declare that turns are missing rather than appear whole"

        {:ok, context}
      end
    end
  end

  # The credential never lands in the cassette — recording sends a real key
  # and the file is committed.
  @cassette_opts [
    cassette_dir: "test/cassettes/anthropic",
    filter_request_headers: ["authorization", "x-api-key"]
  ]

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
