defmodule CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements do
  @moduledoc """
  Show all requirements for a specific story, identified by number or title.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories

  schema do
    field :story, :string, required: true, description: "Story number or title"
  end

  @impl true
  def execute(%{story: story_ref}, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        respond_with_story(scope, story_ref, frame)

      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end

  defp respond_with_story(scope, story_ref, frame) do
    case resolve_story(scope, story_ref) do
      nil ->
        {:reply, RequirementsMapper.error("Story '#{story_ref}' not found"), frame}

      story ->
        # The rows, not a fresh computation of the whole project to show one
        # story's requirements.
        {nodes, _computed_at} = Requirements.cached_all(scope)
        reqs = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

        {:reply, story_response(story, reqs, scope), frame}
    end
  end

  defp resolve_story(scope, ref) do
    if number?(ref),
      do: Stories.get_story_by_number(scope, ref),
      else: find_story_by_title(scope, ref)
  end

  defp find_story_by_title(scope, ref) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        Enum.find(stories, fn story -> String.downcase(story.title) == String.downcase(ref) end)

      _ ->
        nil
    end
  end

  defp number?(ref) do
    case Integer.parse(ref) do
      {_int, ""} -> true
      _ -> false
    end
  end

  # An unsatisfied requirement computed mid-reconcile is not a fact about the
  # story, it is a fact about the pipeline's progress — and the two are
  # indistinguishable in a checkbox. `bdd_specs_exist` going dark reads as "your
  # spec files are gone", which is real enough that the rational next move is to
  # go and find out why. `7b8a61d2` records that detour: eight criteria checked
  # against disk, the ownership lookup read, a regression suspected in
  # spec-file matching, and the answer was to wait twenty seconds.
  #
  # Said here rather than fixed here. `FileSync.reconcile/2` is not one
  # transaction, so the partial projection is real; making it atomic is a
  # lock-duration decision on a database three working copies share.
  defp reconciling_note(scope) do
    case ReconcileRegistry.in_flight(scope.active_working_copy_id) do
      nil ->
        ""

      %{count: count, started_at: started_at} ->
        "\n\n> **Reconciling #{count} observations** since #{DateTime.to_iso8601(started_at)}. " <>
          "Requirements below are computed against a projection that is still landing, so an " <>
          "unsatisfied one may simply not have arrived yet. Ask again when this clears."
    end
  end

  # Ordered so the list reads as the route through the story.
  #
  # The rows arrive in whatever order the query returned, and the render walked
  # them as-is: `qa_complete` second, `three_amigos_complete` — a prerequisite of
  # nearly everything — sixth. An agent reading that cannot tell what to do next
  # from the order, and criterion 8167 says it should ("the gate is listed before
  # QA, so the agent walking the story meets it first"). That was true by accident
  # and stopped being true when `story_issues_resolved` moved ahead of
  # `qa_complete`, which is how the accident surfaced.
  #
  # Depth from the template's prerequisites, then name for a stable tie-break
  # among siblings. Declaration order would not do: it still lists `qa_complete`
  # before `story_issues_resolved`, so it encodes the chain as it was rather than
  # as it is.
  #
  # A name the template does not carry sorts last rather than crashing — a row
  # for a retired definition is a projection question, not a reason to refuse to
  # render the story.
  defp in_dependency_order(reqs) do
    depths = template_depths()
    Enum.sort_by(reqs, &{Map.get(depths, &1.name, 999), &1.name})
  end

  defp template_depths do
    defs = RequirementDefinitionData.story_graph()
    by_id = Map.new(defs, &{&1.id, &1})

    Map.new(defs, &{&1.name, depth_of(&1, by_id)})
  end

  defp depth_of(%{prerequisites: []}, _by_id), do: 0

  defp depth_of(%{prerequisites: prereqs}, by_id) do
    prereqs
    |> Enum.map(fn id ->
      case Map.get(by_id, id) do
        nil -> 0
        parent -> 1 + depth_of(parent, by_id)
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp story_response(story, reqs, scope) do
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)

    lines =
      reqs
      |> in_dependency_order()
      |> Enum.map_join("\n", fn r ->
        status = if r.satisfied, do: "[x]", else: "[ ]"
        "- #{status} **#{r.name}** — #{r.description || "no description"}"
      end)

    text = """
    # #{story.title}

    **Requirements:** #{satisfied}/#{total} satisfied#{reconciling_note(scope)}

    #{lines}
    """

    Response.tool()
    |> Response.text(String.trim(text))
  end
end
