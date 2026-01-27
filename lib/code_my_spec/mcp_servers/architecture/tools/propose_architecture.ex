defmodule CodeMySpec.McpServers.Architecture.Tools.ProposeArchitecture do
  @moduledoc """
  MCP tool for creating an architecture proposal.

  Takes a JSON structure defining bounded contexts, surface components,
  and story mappings. Returns a validated proposal ready for execution.
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
  end

  @impl true
  def execute(params, frame) do
    with {:ok, _scope} <- Validators.validate_project_scope(frame) do
      proposal =
        Proposal.new(%{
          app_name: params.app_name,
          contexts: params[:contexts] || [],
          surface_components: params[:surface_components] || [],
          dependencies: params[:dependencies] || []
        })

      {:reply, ArchitectureMapper.proposal_created(proposal), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end
end
