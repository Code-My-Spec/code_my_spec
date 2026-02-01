defmodule CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal do
  @moduledoc """
  MCP tool for executing an architecture proposal.

  Reads the proposal from docs/architecture/proposal.md, validates it,
  and creates all spec files and database records.

  This is an explicit action - the model must call this tool to execute.
  The stop hook only validates; this tool does the actual creation.
  """

  use Hermes.Server.Component, type: :tool
  require Logger

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.{Environments, Stories}
  alias Hermes.Server.Response

  @proposal_path "docs/architecture/proposal.md"

  schema do
    field :dry_run, :boolean, description: "Preview what would be created without making changes"
  end

  @impl true
  def execute(params, frame) do
    dry_run = Map.get(params, "dry_run", false)
    working_dir = Validators.mcp_working_dir()

    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, app_name} <- get_app_name(scope),
         {:ok, env} <- Environments.create(:cli, working_dir: working_dir),
         {:ok, content} <- read_proposal(env),
         {:ok, proposal} <- Proposal.from_markdown(content, app_name: app_name),
         {:ok, story_ids} <- get_story_ids(scope),
         {:ok, _validated} <- Proposal.validate(proposal, story_ids: story_ids) do
      Environments.destroy(env)

      Logger.debug("[ExecuteProposal] Calling Proposal.execute")
      case Proposal.execute(proposal, scope, dry_run: dry_run, working_dir: working_dir) do
        {:ok, result} ->
          Logger.info("[ExecuteProposal] Execution succeeded: #{inspect(result)}")
          response = format_success(result, dry_run)
          Logger.debug("[ExecuteProposal] Returning response")
          {:reply, response, frame}

        {:error, reason} ->
          Logger.error("[ExecuteProposal] Execution failed: #{inspect(reason)}")
          {:reply, ArchitectureMapper.error("Execution failed: #{inspect(reason)}"), frame}
      end
    else
      {:error, :proposal_not_found} ->
        {:reply, ArchitectureMapper.error("Proposal not found at #{@proposal_path}"), frame}

      {:error, parse_error} when is_binary(parse_error) ->
        {:reply, ArchitectureMapper.error("Parse error: #{parse_error}"), frame}

      {:error, validation_errors} when is_list(validation_errors) ->
        {:reply, ArchitectureMapper.error(format_validation_errors(validation_errors)), frame}

      {:error, reason} ->
        {:reply, ArchitectureMapper.error("Error: #{inspect(reason)}"), frame}
    end
  end

  defp read_proposal(env) do
    case Environments.read_file(env, @proposal_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :proposal_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_story_ids(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> {:ok, Enum.map(stories, & &1.id)}
      {:error, _} -> {:ok, []}
    end
  end

  defp get_app_name(%{active_project: %{module_name: name}}) when is_binary(name), do: {:ok, name}
  defp get_app_name(%{active_project: %{name: name}}) when is_binary(name), do: {:ok, Macro.camelize(name)}
  defp get_app_name(_), do: {:error, "Project must have module_name or name"}

  defp format_success(result, dry_run) do
    message =
      if dry_run do
        """
        ## Dry Run Complete

        Would create:
        - **#{result.created_contexts}** contexts
        - **#{result.created_components}** total components
        - **#{result.linked_stories}** stories linked

        Run without `dry_run: true` to execute.
        """
      else
        """
        ## Architecture Proposal Executed

        Created:
        - **#{result.created_contexts}** contexts
        - **#{result.created_components}** total components
        - **#{result.linked_stories}** stories linked

        Spec files written to `docs/spec/`
        """
      end

    Response.tool()
    |> Response.text(String.trim(message))
  end

  defp format_validation_errors(errors) do
    error_list =
      errors
      |> Enum.map(fn err ->
        details = if err.details, do: " (#{inspect(err.details)})", else: ""
        "- #{err.message}#{details}"
      end)
      |> Enum.join("\n")

    "Validation failed:\n#{error_list}"
  end
end
