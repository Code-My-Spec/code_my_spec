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

  @doc "Create a linked story with its interview and BDD artifacts ready for implementation."
  def create_ready_and_link(context, module_name, attrs) do
    story = create_and_link(context.scope, module_name, attrs)

    :ok =
      CodeMySpecSpex.ProjectStateFixtures.apply_three_amigos_for_story(
        context.scope,
        story,
        persona_id: context.persona_id
      )

    :ok = CodeMySpecSpex.ProjectStateFixtures.apply_bdd_spec_for_story(context, story)
    story
  end

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

    number = extract_number(response)

    # Stories are created parked — they produce no requirements until they
    # are released for development. Spex that set up a story are describing
    # work already in flight, so release it here. Pass
    # `ready_for_dev: false` to exercise the pace gate itself.
    if Keyword.get(attrs, :ready_for_dev, true) do
      {:reply, _resp, _frame} =
        UpdateStory.execute(
          %{story_number: number, ready_for_dev: true},
          frame
        )
    end

    # CreateStory no longer accepts acceptance_criteria (those land via
    # Three Amigos at runtime). Use AddCriterion per description here.
    Enum.each(Keyword.get(attrs, :acceptance_criteria, []), fn description ->
      {:reply, _resp, _frame} =
        AddCriterion.execute(
          %{story_number: number, description: description},
          frame
        )
    end)

    fetch_by_number(scope, number)
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
        %{story_number: number_of(scope, story_id), module_name: module_name},
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
  def fetch(scope, story_id), do: fetch_by_number(scope, number_of(scope, story_id))

  defp fetch_by_number(scope, number) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} = GetStory.execute(%{story_number: number}, frame)

    story = parse_story(response)
    Map.put(story, :id, CodeMySpec.Stories.get_story_by_number(scope, story.number).id)
  end

  # Tools name a story by number; callers here still hold the id.
  defp number_of(scope, story_id), do: CodeMySpec.Stories.get_story(scope, story_id).number

  defp extract_number(response) do
    case Regex.run(~r/^Story (\d+) created/, response_text(response)) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # GetStory's text format (StoriesMapper.story_get_response):
  #
  #     ## Story <number>: <title>
  #
  #     <description>
  #
  #     **Acceptance Criteria:** N total, M verified
  #
  #     - [ ] <description> (criterion <id>)
  #     - [x] <description> (criterion <id>)
  defp parse_story(response) do
    text = response_text(response)
    [_, number, title] = Regex.run(~r/^## Story (\d+): (.+)$/m, text)

    %{
      number: String.to_integer(number),
      title: title,
      criteria: parse_criteria(text)
    }
  end

  # `(criterion N)` is the criterion's number, the only id the agent sees and
  # the one every criterion tool takes, so it is the `:id` here too.
  defp parse_criteria(text) do
    ~r/- \[[ x]\] (.+?) \(criterion (\d+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, description, number] ->
      %{id: String.to_integer(number), description: description}
    end)
  end
end
