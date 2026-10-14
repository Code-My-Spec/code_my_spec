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
    field :story_number, :integer, description: "Story number"
    field :story, :string, description: "Story title, when the number is not known"
  end

  @impl true
  def execute(params, frame) do
    case {Validators.validate_local_scope(frame), story_ref(params)} do
      {{:error, reason}, _ref} ->
        {:reply, RequirementsMapper.error(reason), frame}

      {_scope, nil} ->
        {:reply, RequirementsMapper.error("Pass story_number"), frame}

      {{:ok, scope}, story_ref} ->
        respond_with_story(scope, story_ref, frame)
    end
  end

  defp story_ref(%{story_number: number}) when is_integer(number), do: to_string(number)
  defp story_ref(%{story: ref}) when is_binary(ref), do: ref
  defp story_ref(_params), do: nil

  defp respond_with_story(scope, story_ref, frame) do
    case resolve_story(scope, story_ref) do
      nil ->
        {:reply, RequirementsMapper.error("Story '#{story_ref}' not found"), frame}

      story ->
        # The rows, not a fresh computation of the whole project to show one
        # story's requirements.
        {nodes, _computed_at} = Requirements.cached_all(at_story_copy(scope, story))
        reqs = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

        {:reply, story_response(story, reqs, scope), frame}
    end
  end

  # Read where the story is assigned. A story's requirements are computed at
  # its own copy, so main asking from the main copy read 1092 as 0/0 while
  # team 2's copy held 5/8 (2026-10-12), and main had to take its agents'
  # word for where the story stood.
  defp at_story_copy(scope, %{working_copy_id: copy_id}) when is_binary(copy_id),
    do: %{scope | active_working_copy_id: copy_id}

  defp at_story_copy(scope, _story), do: scope

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

  # Why an unreleased story reads 0/0, said in words.
  #
  # Only a story released for development projects into the graph — `Preloader`
  # filters every story read on `ready_for_dev == true`
  # (`requirements/preloader.ex:269, 445, 465`), and that is working as
  # designed: an unreleased story is a draft, and a draft is not yet anybody's
  # work. What is not designed is the answer an agent gets when it asks.
  #
  # The rows are filtered before this tool sees them, so an unreleased story
  # renders the same "**Requirements:** 0/0 satisfied" a story with a genuinely
  # missing subgraph would produce. `e13b8ccc` is two agents (1086, 1087)
  # reading that as a framework bug: they linked components, re-ran the call
  # minutes apart, traced `settle_owner/1` and `GraphStore.inverted?/0`, and
  # concluded the new per-story projector was broken. The answer was that the
  # stories had never been released, and nothing in the response said so.
  #
  # Said here rather than fixed here, for the same reason as the reconciling
  # note below: the filter is the design, and the gap is that a reader cannot
  # tell an empty answer from an absent one.
  defp unreleased_note(%{ready_for_dev: false}) do
    "\n\n> **This story has not been released for development.** Only a released " <>
      "story projects into the requirements graph, so the list below is empty " <>
      "because none was computed — not because the work is done or missing. " <>
      "Set `ready_for_dev` (mark the story ready) to compute them."
  end

  defp unreleased_note(_story), do: ""

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

    **Requirements:** #{satisfied}/#{total} satisfied#{unreleased_note(story)}#{reconciling_note(scope)}

    #{lines}
    """

    Response.tool()
    |> Response.text(String.trim(text))
  end
end
