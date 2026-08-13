defmodule CodeMySpecSpex.Story984.Criterion2367Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2367 — The tool name reads at a glance and its arguments stay out
  of the way.

  Scanning a transcript is looking for what happened, not for what each call was
  given. The name answers that and the arguments answer the follow-up, so the
  name is always visible and the arguments are one click away rather than
  always on screen.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The name is on screen and the arguments are behind a disclosure" do
    scenario "The tool name reads at a glance and its arguments stay out of the way" do
      when_ "the agent calls a tool with a few hundred bytes of arguments", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("write the file"),
          Fixtures.model_response([
            Fixtures.tool_block("Write", %{
              "file_path" => "lib/example.ex",
              "content" => String.duplicate("defmodule Example do\nend\n", 8)
            })
          ])
        )

        {:ok, context}
      end

      then_ "the tool's name is on screen without expanding anything", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='tool-call'][data-tool='Write']")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the arguments are present but not open", context do
        assert has_element?(context.view, "[data-test='tool-call'] details"),
               "the arguments have to be reachable"

        refute has_element?(context.view, "[data-test='tool-call'] details[open]"),
               "a payload open by default is the wall this criterion exists to stop"

        {:ok, context}
      end
    end
  end
end
