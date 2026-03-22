defmodule CodeMySpec.McpServers.Issues.IssuesMapper do
  @moduledoc """
  Maps issue data to MCP responses using a hybrid format:
  human-readable summary + JSON data for programmatic access.
  """

  alias CodeMySpec.McpServers.Formatters
  alias Anubis.Server.Response

  def issue_created_response(issue) do
    data = issue_data(issue)
    summary = "Issue created: \"#{issue.title}\" [#{issue.severity}] (ID: #{issue.id})"

    hybrid_response(summary, data)
  end

  def validation_error(changeset) do
    Response.tool()
    |> Response.error(Formatters.format_changeset_errors(changeset))
  end

  def error(error) when is_atom(error), do: error |> to_string() |> error()

  def error(error) when is_binary(error) do
    Response.tool()
    |> Response.error(error)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp hybrid_response(summary, data) do
    Response.tool()
    |> Response.text(summary <> "\n\nData: " <> Jason.encode!(data))
  end

  defp issue_data(issue) do
    %{
      id: issue.id,
      title: issue.title,
      severity: issue.severity,
      scope: issue.scope,
      description: issue.description,
      status: issue.status,
      story_id: issue.story_id,
      source_path: issue.source_path
    }
  end
end
