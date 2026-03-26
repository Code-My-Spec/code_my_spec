defmodule CodeMySpec.McpServers.Issues.Tools.ListIssues do
  @moduledoc """
  Lists issues in a project with optional filters.

  Filter by status (incoming, accepted, dismissed, resolved),
  severity (critical, high, medium, low, info), scope (app, qa, docs),
  or story_id.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :status, :string, doc: "Filter by status: incoming, accepted, dismissed, resolved"
    field :severity, :string, doc: "Filter by severity: critical, high, medium, low, info"
    field :scope, :string, doc: "Filter by scope: app, qa, docs"
    field :story_id, :integer, doc: "Filter by related story ID"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} ->
        filters = build_filters(params)
        issues = Issues.list_filtered(scope, filters)
        {:reply, IssuesMapper.issues_list_response(issues, filters), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp build_filters(params) do
    %{}
    |> maybe_put(:status, atomize(params[:status]))
    |> maybe_put(:severity, atomize(params[:severity]))
    |> maybe_put(:scope, atomize(params[:scope]))
    |> maybe_put(:story_id, params[:story_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp atomize(nil), do: nil
  defp atomize(s) when is_binary(s), do: String.to_existing_atom(s)
  defp atomize(a) when is_atom(a), do: a
end
