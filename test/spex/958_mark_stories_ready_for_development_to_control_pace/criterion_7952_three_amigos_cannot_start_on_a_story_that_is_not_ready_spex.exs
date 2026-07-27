defmodule CodeMySpecSpex.Story958.Criterion7952Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7952 — Three Amigos cannot start on a story that is not ready.

  The ready gate sits in FRONT of the existing chain: a parked story does not
  produce a Three Amigos requirement, nor any other. This is what makes the
  gate a gate rather than a label.

  Surface: `get_next_requirement` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Three Amigos cannot start on a story that is not ready" do
    scenario "A parked story produces no requirements at all" do
      given_ "the story \"#{@title}\" is not ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute response.isError, "expected create_story to succeed"

        {:ok, context}
      end

      when_ "the agent asks for the next requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :next_body, response_text(response))}
      end

      then_ "no Three Amigos session is offered for that story", context do
        refute context.next_body =~ "three_amigos_complete",
               "expected no Three Amigos requirement for a parked story, got: #{context.next_body}"

        {:ok, context}
      end

      and_ "no other requirement is offered for that story", context do
        refute context.next_body =~ @title,
               "expected a parked story to be absent from the actionable graph entirely, " <>
                 "got: #{context.next_body}"

        {:ok, context}
      end
    end
  end
end
