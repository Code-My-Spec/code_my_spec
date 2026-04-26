defmodule CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements do
  @moduledoc """
  Show all requirements for a specific story, identified by title or ID.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story, :string, required: true, description: "Story title or story ID"
  end

  @impl true
  def execute(%{story: story_ref}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      story = resolve_story(scope, story_ref)

      case story do
        nil ->
          {:reply, RequirementsMapper.error("Story '#{story_ref}' not found"), frame}

        story ->
          nodes = RequirementGraph.compute_all(scope)
          reqs = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

          {:reply, story_response(story, reqs), frame}
      end
    else
      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end

  defp resolve_story(scope, ref) do
    cond do
      match?({:ok, _}, UUID.info(ref)) -> Stories.get_story(scope, ref)
      integer_id?(ref) -> Stories.get_story(scope, String.to_integer(ref))
      true -> find_story_by_title(scope, ref)
    end
  end

  defp find_story_by_title(scope, ref) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        Enum.find(stories, fn story -> String.downcase(story.title) == String.downcase(ref) end)

      _ ->
        nil
    end
  end

  defp integer_id?(ref) do
    case Integer.parse(ref) do
      {_int, ""} -> true
      _ -> false
    end
  end

  defp story_response(story, reqs) do
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)

    lines =
      Enum.map_join(reqs, "\n", fn r ->
        status = if r.satisfied, do: "[x]", else: "[ ]"
        "- #{status} **#{r.name}** — #{r.description || "no description"}"
      end)

    text = """
    # #{story.title}

    **Status:** #{story.status}
    **Requirements:** #{satisfied}/#{total} satisfied

    #{lines}
    """

    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(String.trim(text))
  end
end
