defmodule CodeMySpecSpex.Story984.Criterion2371Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2371 — Five calls in a row read as one line saying five.

  A turn that calls five tools writes five messages, and five blocks in a
  column is most of a phone screen spent on one turn. What the reader needs
  first is that the agent made five calls; which five is the follow-up.

  Measured on this project: runs are the calls of a single turn, written
  together at the same instant — 20 runs of two to five against 848 lone
  calls. So the grouping is per turn, not a time window.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A run of calls collapses to one line" do
    scenario "Five calls in a row read as one line saying five" do
      when_ "the agent takes a turn that calls five tools", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("survey the project"),
          Fixtures.model_response([
            Fixtures.tool_block("Read", %{"file_path" => "mix.exs"}),
            Fixtures.tool_block("Read", %{"file_path" => "README.md"}),
            Fixtures.tool_block("Grep", %{"pattern" => "defmodule"}),
            Fixtures.tool_block("Bash", %{"command" => "mix compile"}),
            Fixtures.tool_block("Glob", %{"pattern" => "lib/**/*.ex"})
          ])
        )

        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("now summarise"),
          Fixtures.model_response([%{"type" => "text", "text" => "The project compiles."}])
        )

        {:ok, context}
      end

      then_ "they render as one group that says how many", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='tool-call-group'][data-count='5']"),
               "five blocks in a column is most of a phone screen spent on one turn"

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the individual calls are not listed until it is opened", context do
        refute has_element?(context.view, "[data-test='tool-call-group'] details[open]"),
               "a group that opens itself is the column it replaced"

        {:ok, context}
      end

      then_ "the turn after the group is still reachable", context do
        assert context.html =~ "The project compiles.",
               "collapsing exists so the turns around it stay visible"

        {:ok, context}
      end
    end
  end
end
