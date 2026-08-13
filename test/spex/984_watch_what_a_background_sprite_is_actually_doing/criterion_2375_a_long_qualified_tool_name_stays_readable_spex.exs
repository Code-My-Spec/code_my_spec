defmodule CodeMySpecSpex.Story984.Criterion2375Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2375 — A long qualified tool name stays readable.

  MCP tools carry their whole path as a name. `mcp__plugin_codemyspec_local__add_scenario`
  is forty-five characters and appears twenty-one times in this project's
  history — at phone width that is most of a line before anything else renders.

  The block still has to say which tool, so the name cannot simply be dropped:
  "add_scenario" and "add_rule" are the difference between two turns.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A qualified tool name reads at phone width" do
    scenario "A long qualified tool name stays readable" do
      when_ "the agent calls an MCP tool by its qualified name", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("add the scenario"),
          Fixtures.model_response([
            Fixtures.tool_block("mcp__plugin_codemyspec_local__add_scenario", %{
              "title" => "A scenario"
            })
          ])
        )

        {:ok, context}
      end

      then_ "the block still says which tool was used", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(
                 view,
                 "[data-test='tool-call'][data-tool='mcp__plugin_codemyspec_local__add_scenario']"
               ),
               "which MCP tool ran is the difference between two turns"

        assert html =~ "add_scenario",
               "the distinguishing part of the name has to survive on screen"

        {:ok, context}
      end
    end
  end
end
