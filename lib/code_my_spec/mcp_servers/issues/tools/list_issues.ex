defmodule CodeMySpec.McpServers.Issues.Tools.ListIssues do
  @moduledoc """
  Lists issues in a project with optional filters.

  Filter by status (incoming, accepted, dismissed, resolved),
  severity (critical, high, medium, low, info), scope (app, qa, docs,
  framework), or story_id.

  `framework` used to be excluded here, on the grounds that framework issues
  routed to the hosted server rather than being stored locally. That stopped
  being true when the tools moved onto the server — see `CreateIssue`, which
  writes every scope the same way — so they were creatable, visible in an
  unfiltered listing, and impossible to filter for.
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

  # Atoms, not strings, and that is load-bearing rather than stylistic.
  #
  # `validate_filter/3` used to whitelist a string and then call
  # `String.to_existing_atom/1` on it — which raises `:badarg` unless something
  # else has already caused that atom to exist. It runs *before* any query, so
  # on a freshly restarted server `CodeMySpec.Issues.Issue` may not be loaded
  # and its `@scopes` attribute may not have created anything.
  #
  # `:app`, `:qa` and `:docs` survived that by luck: they are common enough to
  # exist for a dozen unrelated reasons. `:framework` is not, and adding it
  # turned every `scope: "framework"` call into `-32603 Internal error` on a
  # cold server — a crash inside a function whose whole job is validation.
  #
  # Written as atoms here, the list itself makes them exist at compile time and
  # the conversion disappears.
  @valid_statuses [:incoming, :accepted, :dismissed, :resolved]
  @valid_severities [:critical, :high, :medium, :low, :info]

  # `framework` belongs here. It was excluded because framework issues were
  # POSTed to the hosted server rather than stored locally — but `CreateIssue`
  # records that this stopped being true when the tools moved onto the server:
  # "Every scope writes the same way. Framework issues used to be special …
  # that path had the server authenticating to itself as a CLI".
  #
  # So they are created locally, appear in an unfiltered listing, and could not
  # be filtered for — the one combination that reads as data loss. An agent
  # asked to work the framework backlog got `Invalid scope: "framework".
  # Allowed: app, qa, docs.` while the issues sat two lines above in the
  # unfiltered list.
  @valid_scopes [:app, :qa, :docs, :framework]

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

  # Matched by string form against a list of atoms, so nothing is converted and
  # the load-order trap above cannot come back.
  defp validate_filter(value, field, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_value, field, value, allowed}}
      atom -> {:ok, atom}
    end
  end

  defp validate_filter(value, field, allowed) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_value, field, value, allowed}}
  end
end
