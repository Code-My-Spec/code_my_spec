defmodule CodeMySpec.McpServers.Architecture.Tools.ValidateProposal do
  @moduledoc """
  MCP tool for validating an architecture proposal.

  Reads from the markdown file created by propose_architecture and validates:
  - Valid module naming conventions
  - Story coverage (all stories mapped)
  - No circular dependencies
  - No duplicate component names
  - No empty contexts
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Architecture.ProposalMarkdown
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias Hermes.Server.Response

  schema do
    field :path, :string, required: true
    field :check_story_coverage, :boolean, default: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, proposal} <- load_proposal(env, params),
         {:ok, validation_opts} <- build_validation_opts(scope, params) do
      Environments.destroy(env)

      case Proposal.validate(proposal, validation_opts) do
        {:ok, _proposal} ->
          response =
            Response.tool()
            |> Response.text("""
            Proposal is valid and ready for execution.

            Summary:
            - Contexts: #{length(proposal.contexts)}
            - Surface Components: #{length(proposal.surface_components)}
            - Dependencies: #{length(proposal.dependencies)}

            Run execute_proposal to create the components.
            """)

          {:reply, response, frame}

        {:error, errors} ->
          {:reply, ArchitectureMapper.proposal_validated({:error, errors}), frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp build_validation_opts(scope, params) do
    if params[:check_story_coverage] do
      case Stories.list_project_stories(scope) do
        {:ok, stories} -> {:ok, [story_ids: Enum.map(stories, & &1.id)]}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
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
