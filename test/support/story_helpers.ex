defmodule CodeMySpecSpex.StoryHelpers do
  @moduledoc """
  Surface-level story setup for spex tests. Drives the same MCP tools
  the agent uses in production — `CreateStory`, `SetStoryComponent`,
  `AddCriterion`, `GetStory` — keeping spec setup on the agent surface.

  Returns plain maps shaped to match what `BddSpecs.spec_file_path/2`
  needs (`:id`, `:title`, `:criteria`, with each criterion exposing
  `:id` and `:description`). No struct dependency on
  `CodeMySpec.Stories.*`, so this stays inside the
  `CodeMySpecSpex` boundary.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @doc """
  Drives the `CreateStory` MCP tool, then `AddCriterion` for each
  acceptance criterion, then `GetStory` to read the persisted story
  (with criteria ids).

  ## Required keys
  - `:title`
  - `:description`
  - `:acceptance_criteria` — list of strings, one per criterion
  """
  @spec create_story(map(), keyword()) :: map()
  def create_story(scope, attrs) do
    frame = %Frame{assigns: %{current_scope: scope}}

    base_params = %{
      title: Keyword.fetch!(attrs, :title),
      description: Keyword.fetch!(attrs, :description)
    }

    params =
      case Keyword.fetch(attrs, :priority) do
        {:ok, priority} -> Map.put(base_params, :priority, priority)
        :error -> base_params
      end

    {:reply, response, _frame} = CreateStory.execute(params, frame)

    story_id = extract_id(response)

    # Stories are created parked — they produce no requirements until they
    # are released for development. Spex that set up a story are describing
    # work already in flight, so release it here. Pass
    # `ready_for_dev: false` to exercise the pace gate itself.
    if Keyword.get(attrs, :ready_for_dev, true) do
      {:reply, _resp, _frame} =
        UpdateStory.execute(
          %{story_id: to_string(story_id), ready_for_dev: true},
          frame
        )
    end

    # CreateStory no longer accepts acceptance_criteria (those land via
    # Three Amigos at runtime). Use AddCriterion per description here.
    Enum.each(Keyword.get(attrs, :acceptance_criteria, []), fn description ->
      {:reply, _resp, _frame} =
        AddCriterion.execute(
          %{story_id: to_string(story_id), description: description},
          frame
        )
    end)

    fetch(scope, story_id)
  end

  @doc """
  Drives the `SetStoryComponent` MCP tool to link a story to the
  component identified by `module_name`. Returns the refreshed
  story map.
  """
  @spec set_component(map(), term(), String.t()) :: map()
  def set_component(scope, story_id, module_name) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, _response, _frame} =
      SetStoryComponent.execute(
        %{story_id: to_string(story_id), module_name: module_name},
        frame
      )

    fetch(scope, story_id)
  end

  @doc """
  Convenience: create a story and link it to a component in one call.
  """
  @spec create_and_link(map(), String.t(), keyword()) :: map()
  def create_and_link(scope, module_name, attrs) do
    story = create_story(scope, attrs)
    set_component(scope, story.id, module_name)
  end

  @doc """
  Drives the `GetStory` MCP tool and returns a map shaped like the
  story struct (`:id`, `:title`, `:criteria`, where each criterion
  carries `:id` and `:description`).
  """
  @spec fetch(map(), term()) :: map()
  def fetch(scope, story_id) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      GetStory.execute(%{story_id: to_string(story_id)}, frame)

    parse_story(response)
  end

  defp extract_id(response) do
    case Regex.run(~r/\(ID:\s*(\d+)\)/, response_text(response)) do
      [_, id_str] -> String.to_integer(id_str)
      _ -> nil
    end
  end

  # GetStory's text format (StoriesMapper.story_get_response):
  #
  #     ## <title> (ID: <id>)
  #
  #     <description>
  #
  #     **Acceptance Criteria:** N total, M verified
  #
  #     - [ ] <description> (criterion <id>)
  #     - [x] <description> (criterion <id>)
  defp parse_story(response) do
    text = response_text(response)
    [_, title, id_str] = Regex.run(~r/^##\s+(.+?)\s+\(ID:\s*(\d+)\)/m, text)

    %{
      id: String.to_integer(id_str),
      number: parse_number(text),
      title: title,
      criteria: parse_criteria(text)
    }
  end

  # The durable number, which is what names a story's spex directory. Separate
  # from the id and not interchangeable with it — see `number_line/1` in
  # `StoriesMapper`.
  defp parse_number(text) do
    case Regex.run(~r/·\s*story\s*(\d+)/, text) do
      [_, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp parse_criteria(text) do
    ~r/- \[[ x]\] (.+?) \(criterion (\d+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, description, id_str] ->
      %{id: String.to_integer(id_str), description: description}
    end)
  end
end
