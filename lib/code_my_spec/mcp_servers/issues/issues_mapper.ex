defmodule CodeMySpec.McpServers.Issues.IssuesMapper do
  @moduledoc """
  Maps issue data to MCP responses using a hybrid format:
  human-readable summary + JSON data for programmatic access.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Formatters

  def issue_created_response(issue) do
    summary = "Issue created: \"#{issue.title}\" [#{issue.severity}] (ID: #{issue.id})"
    hybrid_response(summary, issue_data(issue))
  end

  def issue_get_response(issue) do
    summary = """
    ## #{issue.title} (ID: #{issue.id})

    **Severity:** #{issue.severity} | **Scope:** #{issue.scope} | **Status:** #{issue.status}#{category_segment(issue)}#{story_segment(issue)}

    #{issue.description || "No description"}
    """

    summary =
      if issue.resolution do
        summary <> "\n**Resolution:** #{issue.resolution}"
      else
        summary
      end

    hybrid_response(String.trim(summary), issue_data(issue))
  end

  def issue_updated_response(issue, action) do
    summary =
      "Issue #{action}: \"#{issue.title}\" (ID: #{issue.id})" <>
        category_suffix(issue) <> story_suffix(issue)

    hybrid_response(summary, issue_data(issue))
  end

  def issues_list_response(issues, filters) do
    count = length(issues)

    filter_text =
      filters
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    filter_note = if filter_text != "", do: " (filtered by #{filter_text})", else: ""

    summary =
      if count == 0 do
        "No issues found#{filter_note}."
      else
        lines =
          Enum.map_join(issues, "\n", fn i ->
            "- [#{i.severity}] #{i.title} (#{i.status}) — ID: #{i.id}"
          end)

        "#{count} issues#{filter_note}:\n#{lines}"
      end

    data = %{
      issues: Enum.map(issues, &issue_data/1),
      count: count,
      filters: filters
    }

    hybrid_response(summary, data)
  end

  def not_found_error do
    Response.tool()
    |> Response.error("Issue not found.")
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

  # RemoteClient returns `{:unexpected_status, code, body}` when the
  # server's response doesn't match the expected shape (404, 422, 500).
  # Surface the code + a best-effort body excerpt so the agent (or
  # operator reading the stack) can act on it instead of crashing the
  # tool task with a FunctionClauseError.
  def error({:unexpected_status, status, body}) do
    message =
      case body do
        %{"error" => msg} when is_binary(msg) -> msg
        %{"errors" => errs} -> inspect(errs)
        bin when is_binary(bin) -> bin
        other -> inspect(other)
      end

    Response.tool()
    |> Response.error("Remote API returned #{status}: #{message}")
  end

  # Catch-all for any other shape RemoteClient might return so a
  # tuple/map never crashes the tool. Inspect the value so the
  # operator can see what came back.
  def error(other) do
    Response.tool()
    |> Response.error("Unexpected error: #{inspect(other)}")
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp hybrid_response(summary, _data) do
    Response.tool()
    |> Response.text(summary)
  end

  defp category_segment(%{category: nil}), do: ""
  defp category_segment(%{category: category}), do: " | **Category:** #{category}"

  defp story_segment(%{story_id: nil}), do: ""
  defp story_segment(%{story_id: story_id}), do: " | **Story:** #{story_id}"

  defp category_suffix(%{category: nil}), do: ""
  defp category_suffix(%{category: category}), do: " [#{category}]"

  defp story_suffix(%{story_id: nil}), do: ""
  defp story_suffix(%{story_id: story_id}), do: " → Story #{story_id}"

  defp issue_data(issue) do
    %{
      id: issue.id,
      title: issue.title,
      severity: issue.severity,
      scope: issue.scope,
      description: issue.description,
      status: issue.status,
      resolution: issue.resolution,
      story_id: issue.story_id,
      source_path: issue.source_path
    }
  end
end
