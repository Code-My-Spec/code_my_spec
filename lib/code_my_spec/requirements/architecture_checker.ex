defmodule CodeMySpec.Requirements.ArchitectureChecker do
  @moduledoc """
  Delegate checker for the `architecture_designed` requirement on
  `project_graph`.

  Satisfied when the project has an authored component, or a proposal whose
  referenced stories and formerly present contexts remain active. New stories
  and uncovered contexts do not invalidate an existing plan.

  It used to also demand every released story be linked and every context be
  covered, so one story released unlinked, or one orphan context, held every
  agent on the project behind a project-level gate (Code My Spec, stories
  1113/1114). Linking is per story — `component_linked` — and orphans are an
  architecture finding, not a gate (John, 2026-10-02).

  Returns `{boolean(), map()}` per the checker contract.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Paths
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @proposal_path Paths.proposal_path()

  @no_architecture "No architecture yet — no `#{Paths.proposal_path()}` and no authored " <>
                     "components. Run an architecture session: write the proposal, or " <>
                     "create the components with `create_component`."

  @planned "Architecture planned."

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    proposal_verdict(
      scope,
      Files.get_by_path(scope, @proposal_path),
      Components.any_authored?(scope)
    )
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active project in scope — cannot verify architecture state."}}
  end

  @doc """
  The same verdict, from profiles already in hand instead of fresh queries.
  """
  @spec complete?(Scope.t(), term(), map()) :: {boolean(), map()}
  def complete?(scope, entity, ctx)

  def complete?(scope, _entity, %{files: files, authored?: authored?}) do
    proposal_verdict(scope, Map.get(files.by_path, @proposal_path), authored?)
  end

  def complete?(scope, entity, _ctx), do: complete?(scope, entity)

  defp proposal_verdict(_scope, _file, true), do: {true, %{status: @planned}}
  defp proposal_verdict(_scope, nil, false), do: {false, %{reason: @no_architecture}}

  defp proposal_verdict(scope, file, false) do
    data = Map.get(file.validation_errors || %{}, "data", %{})
    {:ok, stories} = Stories.list_project_stories(scope)
    active_numbers = MapSet.new(stories, & &1.number)
    active_contexts = Components.list_contexts(scope) |> MapSet.new(& &1.module_name)

    stale_stories =
      Enum.reject(data["story_numbers"] || [], &MapSet.member?(active_numbers, &1))

    stale_contexts =
      Enum.reject(data["context_names"] || [], &MapSet.member?(active_contexts, &1))

    if stale_stories == [] and stale_contexts == [] do
      {true, %{status: @planned}}
    else
      details =
        if(stale_stories == [], do: [], else: ["story numbers #{Enum.join(stale_stories, ", ")}"]) ++
          if stale_contexts == [], do: [], else: ["contexts #{Enum.join(stale_contexts, ", ")}"]

      reason =
        "Architecture proposal is out of date: " <>
          Enum.join(details, "; ") <>
          " are no longer active in this project. Update the proposal."

      {false, %{reason: reason}}
    end
  end
end
