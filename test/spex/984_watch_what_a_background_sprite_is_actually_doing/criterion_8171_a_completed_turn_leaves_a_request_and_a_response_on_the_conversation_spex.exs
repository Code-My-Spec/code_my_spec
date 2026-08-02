defmodule CodeMySpecSpex.Story984.Criterion8171Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8171 — A completed turn leaves a request and a response
  on the conversation.

  Surface: the recorder's HTTP endpoint on the local harness (where a
  sprite's agent points ANTHROPIC_BASE_URL), observed through the
  operator's conversation LiveView on the cloud endpoint. The turn is
  driven end to end — nothing is pre-seeded, because the criterion is
  about what taking a turn *produces*.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A sprite's agent turn is recorded" do
    scenario "A completed turn leaves a request and a response on the conversation" do
      when_ "the agent takes one model turn through the recorder", context do
        response =
          with_recorder_cassette("sprite_agent_single_turn", fn ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
              "model" => "claude-opus-5",
              "max_tokens" => 64,
              "messages" => [%{"role" => "user", "content" => "count the open problems"}]
            })
          end)

        assert response.status == 200

        {:ok, Map.put(context, :turn, response)}
      end

      then_ "the operator's conversation shows what the agent was asked", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "count the open problems",
               "expected the turn's request to appear on the conversation"

        {:ok, context}
      end

      and_ "it shows what the model answered", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='message'][data-role='user']"),
               "expected a user-role message for the request"

        assert has_element?(view, "[data-test='message'][data-role='assistant']"),
               "expected an assistant-role message for the response"

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
