defmodule CodeMySpec.McpServers.Architecture.Tools.ProposeArchitecture do
  @moduledoc """
  MCP tool for creating an architecture proposal.

  Creates a markdown file at docs/architecture/proposals/{app_name}.proposal.md
  that can be edited using normal file editing tools, then validated and executed.

  The markdown-based workflow:
  1. propose_architecture - creates the proposal file
  2. Edit the file as needed using Read/Edit tools
  3. validate_proposal - validates the file
  4. execute_proposal - executes from the file
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Architecture.ProposalMarkdown
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias Hermes.Server.Response

  schema do
    field :app_name, :string, required: true
    field :contexts, {:list, :map}, default: []
    field :surface_components, {:list, :map}, default: []
    field :dependencies, {:list, :map}, default: []
  end

  @impl true
  def execute(params, frame) do
    with {:ok, _scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()) do
      proposal =
        Proposal.new(%{
          app_name: params.app_name,
          contexts: params[:contexts] || [],
          surface_components: params[:surface_components] || [],
          dependencies: params[:dependencies] || []
        })

      # Write proposal to markdown file
      markdown = ProposalMarkdown.to_markdown(proposal)
      file_path = ProposalMarkdown.proposal_path(params.app_name)

      case Environments.write_file(env, file_path, markdown) do
        :ok ->
          Environments.destroy(env)

          response =
            Response.tool()
            |> Response.text("""
            Proposal created at: #{file_path}

            You can now:
            1. Read and edit the file using normal Edit tool
            2. Run validate_proposal to check for errors
            3. Run execute_proposal to create the components

            Summary:
            - Contexts: #{length(proposal.contexts)}
            - Surface Components: #{length(proposal.surface_components)}
            - Dependencies: #{length(proposal.dependencies)}
            """)

          {:reply, response, frame}

        {:error, reason} ->
          Environments.destroy(env)
          {:reply, ArchitectureMapper.error("Failed to write proposal: #{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end
end
