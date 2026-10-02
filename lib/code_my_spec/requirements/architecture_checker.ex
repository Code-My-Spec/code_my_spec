defmodule CodeMySpec.Requirements.ArchitectureChecker do
  @moduledoc """
  Delegate checker for the `architecture_designed` requirement on
  `project_graph`.

  Satisfied once the project has an initial architectural plan: `proposal.md`
  was written, or the architecture was authored through the tools (any
  `:authored` component). Once the plan exists it stays satisfied.

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
  alias CodeMySpec.Users.Scope

  @proposal_path Paths.proposal_path()

  @no_architecture "No architecture yet — no `#{Paths.proposal_path()}` and no authored " <>
                     "components. Run an architecture session: write the proposal, or " <>
                     "create the components with `create_component`."

  @planned "Architecture planned."

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    verdict(proposal_present?(scope) or Components.any_authored?(scope))
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active project in scope — cannot verify architecture state."}}
  end

  @doc """
  The same verdict, from profiles already in hand instead of fresh queries.
  """
  @spec complete?(Scope.t(), term(), map()) :: {boolean(), map()}
  def complete?(scope, entity, ctx)

  def complete?(_scope, _entity, %{files: files, authored?: authored?}) do
    verdict(Map.has_key?(files.by_path, @proposal_path) or authored?)
  end

  def complete?(scope, entity, _ctx), do: complete?(scope, entity)

  defp verdict(true), do: {true, %{status: @planned}}
  defp verdict(false), do: {false, %{reason: @no_architecture}}

  # Asked of the synced files, not of a disk: on the light harness the server
  # holds no working copy, and files under `Paths.architecture_dir/0` already
  # sync with role `:architecture`.
  defp proposal_present?(scope), do: Files.get_by_path(scope, @proposal_path) != nil
end
