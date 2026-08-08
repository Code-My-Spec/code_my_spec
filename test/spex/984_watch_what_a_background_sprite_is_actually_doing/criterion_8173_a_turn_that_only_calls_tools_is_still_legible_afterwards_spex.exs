defmodule CodeMySpecSpex.Story984.Criterion8173Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8173 — A turn that only calls tools is still legible afterwards.

  Most of a sprite's turns produce no prose at all — the model answers with
  tool calls and nothing else. Rendering only text would leave the conversation
  blank for exactly the turns that did the work, and an operator reading a
  blank stretch concludes the sprite is idle when it is busiest.

  The tool's arguments matter as much as its name. "Bash" says a command ran;
  `mix spex` says which.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Tool-only turns are recorded in full" do
    scenario "A turn that only calls tools is still legible afterwards" do
      when_ "the agent takes a turn whose entire output is tool calls", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("run the spex suite"),
          Fixtures.model_response([
            Fixtures.tool_block("Bash", %{"command" => "mix spex --stale"})
          ])
        )

        {:ok, context}
      end

      then_ "the operator can see which tool was called", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "Bash", "expected the tool's name to appear on the conversation"

        {:ok, context}
      end

      and_ "they can see the arguments it was called with", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "mix spex",
               "a tool name without its arguments does not say what the sprite did"

        {:ok, context}
      end

      and_ "the turn does not render as empty", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='tool-call']"),
               "expected the tool call to render as its own block"

        {:ok, context}
      end
    end
  end
end
