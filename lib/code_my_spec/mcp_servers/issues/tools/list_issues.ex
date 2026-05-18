defmodule CodeMySpec.McpServers.Issues.Tools.ListIssues do
  @moduledoc """
  Lists issues in a project with optional filters.

  Filter by status (incoming, accepted, dismissed, resolved),
  severity (critical, high, medium, low, info), scope (app, qa, docs,
  framework), or story_id.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :status, :string, doc: "Filter by status: incoming, accepted, dismissed, resolved"
    field :severity, :string, doc: "Filter by severity: critical, high, medium, low, info"
    field :scope, :string, doc: "Filter by scope: app, qa, docs, framework"
    field :story_id, :integer, doc: "Filter by related story ID"
  end

  @valid_statuses ~w(incoming accepted dismissed resolved)
  @valid_severities ~w(critical high medium low info)
  @valid_scopes ~w(app qa docs framework)

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, filters} <- build_filters(params) do
      issues = Issues.list_filtered(scope, filters)
      {:reply, IssuesMapper.issues_list_response(issues, filters), frame}
    else
      {:error, {:invalid_value, field, value, allowed}} ->
        {:reply,
         IssuesMapper.error(
           "Invalid #{field}: #{inspect(value)}. Allowed: #{Enum.join(allowed, ", ")}."
         ), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp build_filters(params) do
    with {:ok, status} <- validate_filter(params[:status], :status, @valid_statuses),
         {:ok, severity} <- validate_filter(params[:severity], :severity, @valid_severities),
         {:ok, scope} <- validate_filter(params[:scope], :scope, @valid_scopes) do
      filters =
        %{}
        |> maybe_put(:status, status)
        |> maybe_put(:severity, severity)
        |> maybe_put(:scope, scope)
        |> maybe_put(:story_id, params[:story_id])

      {:ok, filters}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_filter(nil, _field, _allowed), do: {:ok, nil}

  defp validate_filter(value, field, allowed) when is_binary(value) do
    if value in allowed do
      {:ok, String.to_existing_atom(value)}
    else
      {:error, {:invalid_value, field, value, allowed}}
    end
  end

  defp validate_filter(value, _field, _allowed) when is_atom(value), do: {:ok, value}
end
