defmodule CodeMySpec.McpServers.StoryNumberNamesAStoryTest do
  @moduledoc """
  269c4d59: every tool that names a story takes `story_number`, and the older
  names still reach it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.{ComponentsServer, LocalServer, ScriptableTools, StoryRefs}

  defp tools do
    (LocalServer.registrations() ++
       ScriptableTools.registrations() ++ ComponentsServer.__components__())
    |> Enum.uniq_by(& &1.name)
  end

  defp props(tool), do: Map.get(tool.input_schema, "properties", %{})

  defp story_taking do
    Enum.filter(tools(), fn tool ->
      p = props(tool)

      Map.has_key?(p, "story_number") or Map.has_key?(p, "story_id") or
        (Map.has_key?(p, "entity_id") and Map.has_key?(p, "entity_type"))
    end)
  end

  # Errors about the story argument; a dummy call is free to miss the others.
  defp story_errors(tool, args), do: story_errors(tool.validate_input.(args))

  defp story_errors({:ok, _params}), do: []

  defp story_errors({:error, errors}),
    do: Enum.filter(List.wrap(errors), &(&1.key in [:story_number, :entity_id, :entity_type]))

  test "every story-taking tool declares story_number" do
    names = Enum.map(story_taking(), & &1.name)

    assert "get_story" in names
    assert "show_story_requirements" in names
    assert "start_task" in names

    missing =
      for tool <- story_taking(), not Map.has_key?(props(tool), "story_number"), do: tool.name

    assert missing == []
  end

  for arg <- ["story_number", "story_id", "entity_id", "story"] do
    test "every story-taking tool accepts #{arg} = \"35\"" do
      for tool <- story_taking(),
          not Map.has_key?(props(tool), unquote(arg)) or unquote(arg) == "story_number" do
        args = StoryRefs.normalize_args(tool.input_schema, %{unquote(arg) => "35"})

        assert args["story_number"] == 35 or
                 {args["entity_type"], args["entity_id"]} == {"story", "35"},
               "#{tool.name} did not read #{unquote(arg)}: #{inspect(args)}"

        assert story_errors(tool, args) == [],
               "#{tool.name}: #{inspect(story_errors(tool, args))}"
      end
    end
  end

  test "a tool's own argument of an alias's name is left alone" do
    create = Enum.find(tools(), &(&1.name == "create_story"))
    args = %{"title" => "t", "story" => "As a user, I want x so that y"}

    assert StoryRefs.normalize_args(create.input_schema, args) == args
  end

  describe "from a script" do
    setup do
      scope = full_scope_fixture()
      %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
    end

    defp run(frame, script) do
      {:reply, response, _frame} = RunScript.execute(%{script: script}, frame)

      {response.isError,
       response |> Response.to_protocol() |> get_in(["content"]) |> hd() |> Map.get("text")}
    end

    test "get_story takes story_id as a string", %{scope: scope, frame: frame} do
      story = story_fixture(scope, %{title: "Named by an alias"})

      assert {false, text} = run(frame, ~s[return get_story({ story_id = "#{story.number}" })])
      assert text =~ "Named by an alias"
    end

    test "show_story_requirements takes story_number", %{scope: scope, frame: frame} do
      story = story_fixture(scope, %{title: "Requirements by number"})

      assert {false, text} =
               run(frame, ~s[return show_story_requirements({ story_number = #{story.number} })])

      assert text =~ "Requirements by number"
    end
  end

  test "a direct call is normalised before validation" do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "get_next_requirement", "arguments" => %{"story_id" => "7"}}
    }

    assert %{"params" => %{"arguments" => %{"story_number" => 7}}} =
             StoryRefs.normalize_request(request, LocalServer.registrations())
  end
end
