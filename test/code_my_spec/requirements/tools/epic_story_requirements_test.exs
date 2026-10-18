defmodule CodeMySpec.Requirements.Tools.EpicStoryRequirementsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.{Epics, Requirements, Stories}

  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic

  test "epic assignment preserves every per-story requirement read" do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, epic} = Epics.create_epic(scope, %{name: "Requirement visibility fixture"})
    Requirements.recompute(scope)
    frame = %Frame{assigns: %{current_scope: scope}}
    params = %{entity_type: "story", entity_id: to_string(story.number)}

    assert {:ok, before_rows} =
             ToolLibrary.data(
               "list_requirements",
               params,
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    refute before_rows == []
    before_summary = call("show_story_requirements", %{story_number: story.number}, frame)

    before_details =
      Map.new(before_rows, fn row ->
        {row["name"], call("show_requirement", Map.put(params, :name, row["name"]), frame)}
      end)

    call(AssignStoryToEpic, %{story_number: story.number, epic_name: epic.name}, frame)
    assert Stories.get_story_by_number(scope, story.number).epic_id == epic.id

    assert {:ok, after_rows} =
             ToolLibrary.data(
               "list_requirements",
               params,
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert Enum.sort_by(after_rows, & &1["name"]) ==
             Enum.sort_by(before_rows, & &1["name"])

    assert call("show_story_requirements", %{story_number: story.number}, frame) == before_summary

    for {name, detail} <- before_details do
      assert call("show_requirement", Map.put(params, :name, name), frame) == detail
    end
  end

  test "all three readers follow the story's assigned copy before and after epic assignment" do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

    {:ok, team} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "epic-read-team",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(scope, story, %{working_copy_id: team.id})
    {:ok, epic} = Epics.create_epic(scope, %{name: "Assigned story epic"})
    Requirements.recompute(%{scope | active_working_copy_id: team.id})
    frame = %Frame{assigns: %{current_scope: scope}}
    params = %{entity_type: "story", entity_id: to_string(story.number)}

    assert {:ok, before_rows} =
             ToolLibrary.data(
               "list_requirements",
               params,
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    refute before_rows == []
    before_summary = call("show_story_requirements", %{story_number: story.number}, frame)

    before_details =
      Map.new(before_rows, fn row ->
        {row["name"], call("show_requirement", Map.put(params, :name, row["name"]), frame)}
      end)

    call(AssignStoryToEpic, %{story_number: story.number, epic_name: epic.name}, frame)
    assert Stories.get_story_by_number(scope, story.number).epic_id == epic.id

    assert {:ok, after_rows} =
             ToolLibrary.data(
               "list_requirements",
               params,
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert Enum.sort_by(after_rows, & &1["name"]) ==
             Enum.sort_by(before_rows, & &1["name"])

    assert call("show_story_requirements", %{story_number: story.number}, frame) == before_summary

    for {name, detail} <- before_details do
      assert call("show_requirement", Map.put(params, :name, name), frame) == detail
    end
  end

  defp call(name, params, frame) when is_binary(name) do
    context = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
    assert {:ok, text} = ToolLibrary.run(name, params, context)
    text
  end

  defp call(tool, params, frame) do
    assert {:reply, response, _} = tool.execute(params, frame)
    text = hd(Response.to_protocol(response)["content"])["text"]
    refute response.isError, text
    text
  end
end
