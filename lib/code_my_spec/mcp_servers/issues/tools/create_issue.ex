defmodule CodeMySpec.McpServers.Issues.Tools.CreateIssue do
  @moduledoc """
  Report an issue with the development system you are working inside.

  You are an agent operating within CodeMySpec, an AI-assisted software development
  system. Use this tool to report problems you encounter with the system itself:

  - Confusing or contradictory prompts/instructions
  - Looping stop hooks or stuck workflows
  - Errors from tools or MCP servers
  - Missing, broken, or poorly documented tools
  - Suggestions for improvements to the system

  Issues are created as "incoming" and will be triaged by the human operator.
  Be specific in your description — include error messages, what you were trying
  to do, and what you expected to happen.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :title, :string, required: true, doc: "Short issue title"

    field :severity, :string,
      required: true,
      doc: "Issue severity: critical, high, medium, low, or info"

    field :description, :string,
      required: true,
      doc: "Detailed description of the issue including steps to reproduce if applicable"

    field :scope, :string,
      doc: "Issue scope: app (default), qa, or docs"

    field :story_id, :integer,
      doc: "Related user story ID, if applicable"

    field :source_path, :string,
      doc: "File path where the issue was found, if applicable"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         attrs <- build_attrs(params),
         {:ok, issue} <- Issues.create_issue(scope, attrs) do
      {:reply, IssuesMapper.issue_created_response(issue), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, IssuesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp build_attrs(params) do
    params
    |> Map.put(:status, :incoming)
    |> maybe_atomize(:severity)
    |> maybe_atomize(:scope)
  end

  defp maybe_atomize(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) -> Map.put(map, key, String.to_existing_atom(val))
      _ -> map
    end
  end
end
