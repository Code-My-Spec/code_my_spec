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
    field :app_name, :string
    field :check_story_coverage, :boolean, default: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, proposal} <- load_proposal(env, params) do
      Environments.destroy(env)

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

  defp load_proposal(env, params) do
    file_path = params[:app_name] && ProposalMarkdown.proposal_path(params.app_name)

    if is_nil(file_path) do
      {:error, "Must provide app_name"}
    else
      case Environments.read_file(env, file_path) do
        {:ok, content} ->
          ProposalMarkdown.from_markdown(content)

        {:error, :enoent} ->
          {:error, "Proposal file not found: #{file_path}. Run propose_architecture first."}

        {:error, reason} ->
          {:error, "Failed to read proposal: #{inspect(reason)}"}
      end
    end
  end
end
