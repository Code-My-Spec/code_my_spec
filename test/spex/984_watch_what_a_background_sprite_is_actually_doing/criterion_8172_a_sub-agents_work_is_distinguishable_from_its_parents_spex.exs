defmodule CodeMySpecSpex.Story984.Criterion8172Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8172 — A sub-agent's work is distinguishable from its
  parent's.

  Two turns go through the recorder — one from the main agent, one
  from a QA sub-agent — and the operator must be able to tell them
  apart on the conversation. Attribution is the whole point: a run
  where the sub-agent's turns are silently merged into its parent's
  reads as one confused agent.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sub-agent turns are attributed to the sub-agent" do
    scenario "A sub-agent's work is distinguishable from its parent's" do
      given_ "the main agent has taken a turn", context do
        with_recorder_cassette("sprite_main_agent_turn", fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
            "model" => "claude-opus-5",
            "max_tokens" => 64,
            "messages" => [%{"role" => "user", "content" => "delegate the QA pass"}]
          })
        end)

        {:ok, context}
      end

      when_ "a QA sub-agent takes a turn of its own", context do
        response =
          with_recorder_cassette("sprite_qa_subagent_turn", fn ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("x-agent-role", "qa")
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
              "model" => "claude-opus-5",
              "max_tokens" => 64,
              "messages" => [%{"role" => "user", "content" => "walk the signup journey"}]
            })
          end)

        assert response.status == 200

        {:ok, context}
      end

      then_ "the sub-agent's turn is marked as the sub-agent's", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='message'][data-agent-role='qa']"),
               "expected the QA sub-agent's turn to carry its agent role"

        {:ok, context}
      end

      and_ "the main agent's turn is not attributed to the sub-agent", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='message']:not([data-agent-role='qa'])"),
               "expected the main agent's turn to remain distinct from the sub-agent's"

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
