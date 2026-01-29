defmodule CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal do
  @moduledoc """
  MCP tool for executing an architecture proposal.

  Reads from the markdown file created by propose_architecture and:
  - Creates all spec files for the proposed components
  - Creates database records for tracking
  - Optionally links stories to the components they satisfy

  Use `dry_run: true` to preview what would be created without making changes.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Architecture.ProposalMarkdown
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :path, :string, required: true
    field :dry_run, :boolean, default: false
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, proposal} <- load_proposal(env, params) do
      Environments.destroy(env)

      dry_run = params[:dry_run] || false

      case Proposal.execute(proposal, scope, dry_run: dry_run, working_dir: Validators.mcp_working_dir()) do
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

  defp load_proposal(env, params) do
    case Environments.read_file(env, params.path) do
      {:ok, content} ->
        ProposalMarkdown.from_markdown(content)

      {:error, :enoent} ->
        {:error, "Proposal file not found: #{params.path}"}

      {:error, reason} ->
        {:error, "Failed to read proposal: #{inspect(reason)}"}
    end
  end
end
