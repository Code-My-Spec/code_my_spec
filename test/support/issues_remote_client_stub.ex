defmodule CodeMySpec.Issues.RemoteClientStub do
  @moduledoc """
  Test-env in-process stand-in for `CodeMySpec.Issues.RemoteClient`.

  The local CLI's only contract with framework-scoped issues is
  `create_issue/3` — fire-and-forget to the CodeMySpec server. After
  creation, framework issues are administered server-side (humans +
  server tooling); the agent never reads, accepts, dismisses, or
  resolves them through the local MCP surface. So this stub only
  mirrors that one method, plus inspection helpers for spex.

  Wired in via `config :code_my_spec, :issues_remote_client,
  CodeMySpec.Issues.RemoteClientStub` in `config/test.exs`. The MCP
  `create_issue` tool fetches the configured module at call time, so
  production always lands on the real HTTP client.

  State is process-local ETS so concurrent tests do not bleed framework
  issues into each other.
  """

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Users.Scope

  @table_key {__MODULE__, :table}

  @doc "Resets the per-process stub state."
  def reset do
    case Process.get(@table_key) do
      nil -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc "Returns the framework issues the stub captured this test."
  def stored_issues do
    table = ensure_table()

    table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, issue} -> issue end)
  end

  # ---------------------------------------------------------------------------
  # RemoteClient public surface (subset)
  # ---------------------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs, _opts \\ []) do
    id = Ecto.UUID.generate()
    issue = build_issue(scope, attrs, id)

    insert(issue)
    {:ok, issue}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_issue(scope, attrs, id) do
    %Issue{
      id: id,
      title: fetch(attrs, :title),
      severity: parse_atom(fetch(attrs, :severity)),
      scope: parse_atom(fetch(attrs, :scope)) || :framework,
      description: fetch(attrs, :description),
      status: parse_atom(fetch(attrs, :status)) || :incoming,
      category: parse_atom(fetch(attrs, :category)),
      resolution: fetch(attrs, :resolution),
      source: fetch(attrs, :source),
      story_id: fetch(attrs, :story_id),
      source_path: fetch(attrs, :source_path),
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp ensure_table do
    case Process.get(@table_key) do
      nil ->
        table = :ets.new(:issues_remote_stub, [:set, :private])
        Process.put(@table_key, table)
        table

      table ->
        table
    end
  end

  defp insert(%Issue{id: id} = issue) do
    table = ensure_table()
    :ets.insert(table, {id, issue})
    :ok
  end

  defp fetch(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(value) when is_atom(value), do: value

  defp parse_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end
end
