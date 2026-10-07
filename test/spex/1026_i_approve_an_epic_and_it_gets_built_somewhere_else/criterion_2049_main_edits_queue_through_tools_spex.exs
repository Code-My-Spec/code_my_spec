defmodule CodeMySpecSpex.Story1026.Criterion2049Spex do
  @moduledoc """
  Story 1026 — Main adds and removes stories and epics through tools.
  Calls go through run_script with main's actual grant, including the tools
  that remain to be built. Queue changes are observed on the destination page.
  The proposed tool names describe placement and removal separately.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias CodeMySpecSpex.WorkingCopyHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main edits individual stories and whole epics through queue tools", criterion: 2049 do
    scenario "Main adds a single story without its sibling" do
      given_ "main and an empty destination with a two-story epic", context do
        {:ok, queue_context(context, false)}
      end

      when_ "main calls the story placement tool", context do
        {:ok, invoke(context, "assign_story_to_working_copy", :story)}
      end

      then_ "only the selected story is queued", context do
        successful(context)
        view = copy_page(context)
        assert has_element?(view, queued(context.selected))
        refute has_element?(view, queued(context.sibling))
        {:ok, context}
      end
    end

    scenario "Main removes one story without removing its sibling" do
      given_ "main and a destination holding a two-story epic", context do
        {:ok, queue_context(context, true)}
      end

      when_ "main calls the story removal tool", context do
        {:ok, invoke(context, "unassign_story_from_working_copy", :story)}
      end

      then_ "the sibling stays queued while the selected story leaves", context do
        successful(context)
        view = copy_page(context)
        assert has_element?(view, queued(context.sibling))
        refute has_element?(view, queued(context.selected))
        {:ok, context}
      end
    end

    scenario "Main adds a whole epic" do
      given_ "main and an empty destination with a two-story epic", context do
        {:ok, queue_context(context, false)}
      end

      when_ "main calls the epic placement tool", context do
        {:ok, invoke(context, "assign_epic_to_working_copy", :epic)}
      end

      then_ "both stories are queued on the destination", context do
        successful(context)
        view = copy_page(context)
        assert has_element?(view, queued(context.selected))
        assert has_element?(view, queued(context.sibling))
        {:ok, context}
      end
    end

    scenario "Main removes a whole unstarted epic" do
      given_ "main and a destination holding a two-story epic", context do
        {:ok, queue_context(context, true)}
      end

      when_ "main calls the epic removal tool", context do
        {:ok, invoke(context, "unassign_epic_from_working_copy", :epic)}
      end

      then_ "both stories leave the destination queue", context do
        successful(context)
        view = copy_page(context)
        assert has_element?(view, "[data-test='working-copy-show']")
        refute has_element?(view, queued(context.selected))
        refute has_element?(view, queued(context.sibling))
        {:ok, context}
      end
    end
  end

  defp queue_context(context, placed?) do
    context = Slice.main_copy(context)

    reply =
      WorkingCopyHelpers.join_working_copy(
        context,
        "/workspace/main-queue-tools",
        "Tool destination"
      )

    copy_id = reply["working_copy_id"]
    frame = %Frame{assigns: %{current_scope: context.main_scope, agent_id: context.main.id}}
    {:reply, created, _} = CreateEpic.execute(%{name: "Tool-managed epic"}, frame)
    false = created.isError
    [_, epic_id] = Regex.run(~r/ID: ([^,\s]+)/, response_text(created))

    stories =
      for title <- ["Selected tool story", "Sibling tool story"] do
        story =
          StoryHelpers.create_story(context.scope,
            title: title,
            description: "Unstarted work managed through tools",
            acceptance_criteria: ["It works"]
          )

        {:reply, assigned, _} =
          AssignStoryToEpic.execute(
            %{story_number: story.number, epic_name: "Tool-managed epic"},
            frame
          )

        false = assigned.isError
        story
      end

    place_epic(placed?, frame, epic_id, copy_id)

    [selected, sibling] = stories

    Map.merge(context, %{
      queue_frame: frame,
      destination: copy_id,
      epic_id: epic_id,
      selected: selected,
      sibling: sibling
    })
  end

  defp place_epic(false, _frame, _epic_id, _copy_id), do: :ok

  defp place_epic(true, frame, epic_id, copy_id) do
    {:reply, placed, _} =
      AssignEpicToWorkingCopy.execute(
        %{epic_id: epic_id, working_copy_id: copy_id},
        frame
      )

    false = placed.isError
  end

  defp subject(context, :story), do: "story_number = #{context.selected.number}"
  defp subject(context, :epic), do: "epic_id = '#{context.epic_id}'"

  defp invoke(context, tool, kind) do
    subject = subject(context, kind)

    script = """
    local result, err = #{tool}({#{subject}, working_copy_id = '#{context.destination}'})
    if result == nil then error(err.message) end
    return result
    """

    {:reply, response, _} = RunScript.execute(%{script: script}, context.queue_frame)
    Map.put(context, :tool_response, response)
  end

  defp successful(context),
    do: refute(context.tool_response.isError, response_text(context.tool_response))

  defp copy_page(context) do
    {:ok, view, _html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{context.destination}"
      )

    view
  end

  defp queued(story),
    do: "[data-test='queued-story'][data-story-number='#{story.number}']"
end
