defmodule CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal do
  @moduledoc """
  MCP tool for executing an architecture proposal.

  Creates all spec files and database records for the proposed components.
  Optionally links stories to the components they satisfy.

  Use `dry_run: true` to preview what would be created without making changes.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :app_name, :string, required: true
    field :contexts, {:array, :map}, default: []
    field :surface_components, {:array, :map}, default: []
    field :dependencies, {:array, :map}, default: []
    field :dry_run, :boolean, default: false
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

      dry_run = params[:dry_run] || false

      case Proposal.execute(proposal, scope, dry_run: dry_run) do
        {:ok, result} ->
          {:reply, ArchitectureMapper.proposal_executed(result, dry_run), frame}

        {:error, reason} ->
          {:reply, ArchitectureMapper.error("Execution failed: #{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end
end
