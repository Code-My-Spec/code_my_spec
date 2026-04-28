defmodule CodeMySpecSpex.StoryHelpers do
  @moduledoc """
  Surface-level story setup for spex tests. Drives the same MCP tools
  the agent uses in production — `CreateStory`, `SetStoryComponent`,
  `GetStory` — keeping spec setup on the agent surface.

  Returns plain maps shaped to match what `BddSpecs.spec_file_path/2`
  needs (`:id`, `:title`, `:criteria`, with each criterion exposing
  `:id` and `:description`). No struct dependency on
  `CodeMySpec.Stories.*`, so this stays inside the
  `CodeMySpecSpex` boundary.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @doc """
  Drives the `CreateStory` MCP tool, then `GetStory` to read the
  persisted story (with criteria ids).

  ## Required keys
  - `:title`
  - `:description`
  - `:acceptance_criteria` — list of strings, one per criterion
  """
  @spec create_story(map(), keyword()) :: map()
  def create_story(scope, attrs) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      CreateStory.execute(
        %{
          title: Keyword.fetch!(attrs, :title),
          description: Keyword.fetch!(attrs, :description),
          acceptance_criteria: Keyword.fetch!(attrs, :acceptance_criteria)
        },
        frame
      )

    response
    |> extract_id()
    |> then(&fetch(scope, &1))
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
      title: title,
      criteria: parse_criteria(text)
    }
  end

  defp parse_criteria(text) do
    ~r/- \[[ x]\] (.+?) \(criterion (\d+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, description, id_str] ->
      %{id: String.to_integer(id_str), description: description}
    end)
  end
end
