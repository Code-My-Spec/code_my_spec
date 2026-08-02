defmodule CodeMySpecSpex.Story984.Criterion8173Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8173 — A turn that only calls tools is still legible
  afterwards.

  The turn under test emits no prose at all — only tool calls. This is
  the criterion the story exists for: the previous recorder accumulated
  assistant text and nothing else, so a turn like this one recorded as
  empty, and the evidence for why a run believed a red suite was green
  was exactly the evidence that got dropped.
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Tool-only turns are recorded in full" do
    scenario "A turn that only calls tools is still legible afterwards" do
      when_ "the agent takes a turn whose entire output is tool calls", context do
        response =
          with_recorder_cassette("sprite_tool_only_turn", fn ->
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
              "model" => "claude-opus-5",
              "max_tokens" => 256,
              "messages" => [%{"role" => "user", "content" => "run the spex suite"}]
            })
          end)

        assert response.status == 200

        {:ok, context}
      end

      then_ "the operator can see which tool was called", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "Bash", "expected the tool's name to appear on the conversation"

        {:ok, context}
      end

      and_ "they can see the arguments it was called with", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "mix spex",
               "expected the tool call's arguments to appear on the conversation"

        {:ok, context}
      end

      and_ "the turn does not render as empty", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='tool-call']"),
               "expected a tool call to be rendered, not an empty assistant turn"

        refute has_element?(view, "[data-test='empty-turn']"),
               "a turn made entirely of tool calls must not render as an empty turn"

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
