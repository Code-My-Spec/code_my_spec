defmodule CodeMySpecSpex.Story984.Criterion2373Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2373 — A lone call is not dressed up as a group.

  The guard on grouping. Most calls are alone — 848 of them against 20 runs on
  this project — so a rule that wrapped every call in a group of one would make
  the common case worse to save the rare one, and add a click to reach what used
  to be on screen.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "One call stays one call" do
    scenario "A lone call is not dressed up as a group" do
      when_ "the agent takes a turn that calls exactly one tool", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("run the suite"),
          Fixtures.model_response([Fixtures.tool_block("Bash", %{"command" => "mix test"})])
        )

        {:ok, context}
      end

      then_ "it renders on its own, naming the tool", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='tool-call'][data-tool='Bash']")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "it is not wrapped in a group", context do
        refute has_element?(context.view, "[data-test='tool-call-group']"),
               "grouping one call adds a click to reach what was already on screen"

        {:ok, context}
      end
    end
  end
end
