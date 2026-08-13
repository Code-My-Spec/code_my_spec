defmodule CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements do
  @moduledoc """
  Show all requirements for a specific story, identified by title or ID.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories

  schema do
    field :story, :string, required: true, description: "Story title or story ID"
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
        nodes = RequirementGraph.compute_all(scope)
        reqs = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

        {:reply, story_response(story, reqs, scope), frame}
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
    case ReconcileRegistry.in_flight(scope.active_harness_id) do
      nil ->
        ""

      %{count: count, started_at: started_at} ->
        "\n\n> **Reconciling #{count} observations** since #{DateTime.to_iso8601(started_at)}. " <>
          "Requirements below are computed against a projection that is still landing, so an " <>
          "unsatisfied one may simply not have arrived yet. Ask again when this clears."
    end
  end

  defp story_response(story, reqs, scope) do
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)

    lines =
      Enum.map_join(reqs, "\n", fn r ->
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
