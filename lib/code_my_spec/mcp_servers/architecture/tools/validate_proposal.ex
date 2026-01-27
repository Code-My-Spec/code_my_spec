defmodule CodeMySpec.McpServers.Architecture.Tools.ValidateProposal do
  @moduledoc """
  MCP tool for validating an architecture proposal.

  Checks for:
  - Valid module naming conventions
  - Story coverage (all stories mapped)
  - No circular dependencies
  - No duplicate component names
  - No empty contexts
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :app_name, :string, required: true
    field :contexts, {:array, :map}, default: []
    field :surface_components, {:array, :map}, default: []
    field :dependencies, {:array, :map}, default: []
    field :check_story_coverage, :boolean, default: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame) do
      proposal =
        Proposal.new(%{
          app_name: params.app_name,
          contexts: params[:contexts] || [],
          surface_components: params[:surface_components] || [],
          dependencies: params[:dependencies] || []
        })

      validation_opts =
        if params[:check_story_coverage] do
          story_ids =
            scope
            |> Stories.list_project_stories()
            |> Enum.map(& &1.id)

          [story_ids: story_ids]
        else
          []
        end

      result = Proposal.validate(proposal, validation_opts)
      {:reply, ArchitectureMapper.proposal_validated(result), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end
end
