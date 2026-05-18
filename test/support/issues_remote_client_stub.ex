defmodule CodeMySpec.Issues.RemoteClientStub do
  @moduledoc """
  Test-env in-process stand-in for `CodeMySpec.Issues.RemoteClient`.

  Supports two use cases:

  1. Framework-scoped issue creation (original use case): `create_issue/3`
     fires-and-forgets to the stub's "remote" store.

  2. Triage sync scenarios (new): seed incoming server-side issues via
     `seed_incoming_issue/2`, simulate server outages via
     `simulate_unreachable/1`, drive triage-start pulls via
     `pull_to_local/1`, and introspect disposition syncs via
     `update_calls_for/1`.

  Wired in via `config :code_my_spec, :issues_remote_client,
  CodeMySpec.Issues.RemoteClientStub` in `config/test.exs`. The MCP
  Issues tools fetch the configured module at call time, so production
  always lands on the real HTTP client.

  State is process-local ETS so concurrent tests do not bleed into each
  other. All public helpers operate on the calling process's tables.
  """

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Users.Scope

  # ETS table keys stored in process dictionary
  @framework_table_key {__MODULE__, :framework_table}
  @remote_table_key {__MODULE__, :remote_table}
  @update_calls_key {__MODULE__, :update_calls}
  @unreachable_key {__MODULE__, :unreachable}

  # ---------------------------------------------------------------------------
  # Test-setup helpers
  # ---------------------------------------------------------------------------

  @doc """
  Resets all per-process stub state (framework issues, remote issues,
  update call log, unreachable flag).
  """
  def reset do
    for key <- [@framework_table_key, @remote_table_key, @update_calls_key] do
      case Process.get(key) do
        nil -> :ok
        table -> :ets.delete_all_objects(table)
      end
    end

    Process.put(@unreachable_key, false)
    :ok
  end

  @doc """
  Seeds a server-side incoming issue into the stub's remote store.

  `attrs` must include at least `:id`, `:title`, `:severity`, `:scope`,
  and `:description`. The seeded issue is NOT in the local DB yet —
  call `pull_to_local/1` (or let `TriageIssues.command/2` do it via
  triage start) to import it.

  Returns `{:ok, %Issue{}}`.
  """
  def seed_incoming_issue(%Scope{} = scope, attrs) do
    id = fetch(attrs, :id) || Ecto.UUID.generate()
    issue = build_issue(scope, attrs, id, "server")
    remote_insert(issue)
    {:ok, issue}
  end

  @doc """
  Toggles the simulated-unreachable flag.

  When `true`, all remote-client methods that contact the "server"
  (`list_incoming_issues/2`, `update_issue/4`) return
  `{:error, :server_unreachable}`.

  Returns `:ok`.
  """
  def simulate_unreachable(flag) when is_boolean(flag) do
    Process.put(@unreachable_key, flag)
    :ok
  end

  @doc """
  Pulls all server-side seeded issues into the local DB.

  Mirrors what `TriageIssues.command/2` does on triage start: fetches
  from the stub's remote store and upserts into the Ecto Repo with
  `source: "server"` so `AcceptIssue` can detect server-origin issues
  later.

  Returns `{:ok, [%Issue{}]}` on success or `{:error, reason}` when
  the stub is simulating unreachability.
  """
  def pull_to_local(%Scope{} = scope) do
    case list_incoming_issues(scope) do
      {:ok, issues} ->
        Enum.each(issues, fn issue ->
          attrs = %{
            title: issue.title,
            severity: issue.severity,
            scope: issue.scope,
            description: issue.description,
            source: "server",
            status: :incoming,
            story_id: issue.story_id,
            source_path: issue.source_path
          }

          changeset =
            %Issue{id: issue.id}
            |> Issue.changeset(attrs)
            |> Ecto.Changeset.put_change(:project_id, scope.active_project_id)
            |> Ecto.Changeset.put_change(:account_id, scope.active_account_id)
            |> Ecto.Changeset.put_change(:source, "server")
            |> Ecto.Changeset.put_change(:status, :incoming)

          CodeMySpec.Repo.insert(changeset,
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: :id
          )
        end)

        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns all recorded remote `update_issue` calls for the given issue ID.

  Each entry is a map with at least `:issue_id` and `:attrs`.
  Returns `[]` if no calls were recorded for this issue.
  """
  def update_calls_for(issue_id) do
    table = ensure_update_calls_table()

    table
    |> :ets.tab2list()
    |> Enum.filter(fn {id, _call} -> id == issue_id end)
    |> Enum.map(fn {_id, call} -> call end)
  end

  @doc "Returns all framework issues the stub captured this test."
  def stored_issues do
    table = ensure_framework_table()

    table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, issue} -> issue end)
  end

  # ---------------------------------------------------------------------------
  # RemoteClient public surface
  # ---------------------------------------------------------------------------

  @doc """
  Mimics `RemoteClient.list_incoming_issues/2`.

  Returns all server-side seeded issues, or `{:error, :server_unreachable}`
  when unreachable simulation is active.
  """
  def list_incoming_issues(%Scope{} = _scope, _opts \\ []) do
    if unreachable?() do
      {:error, :server_unreachable}
    else
      table = ensure_remote_table()

      issues =
        table
        |> :ets.tab2list()
        |> Enum.map(fn {_id, issue} -> issue end)

      {:ok, issues}
    end
  end

  @doc """
  Mimics `RemoteClient.create_issue/3`.

  Stores the issue in the framework-issues table and returns `{:ok, issue}`.
  """
  def create_issue(%Scope{} = scope, attrs, _opts \\ []) do
    id = Ecto.UUID.generate()
    issue = build_issue(scope, attrs, id, nil)

    framework_insert(issue)
    {:ok, issue}
  end

  @doc """
  Mimics `RemoteClient.update_issue/4`.

  Records the call in the per-process update-calls table so
  `update_calls_for/1` can introspect it. Returns
  `{:error, :server_unreachable}` when unreachable simulation is active.
  """
  def update_issue(%Scope{} = _scope, issue_id, attrs, _opts \\ []) do
    if unreachable?() do
      {:error, :server_unreachable}
    else
      table = ensure_update_calls_table()
      call = Map.put(attrs, :issue_id, issue_id)
      :ets.insert(table, {issue_id, call})
      {:ok, %{id: issue_id}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp unreachable? do
    Process.get(@unreachable_key, false)
  end

  defp build_issue(scope, attrs, id, default_source) do
    %Issue{
      id: id,
      title: fetch(attrs, :title),
      severity: parse_atom(fetch(attrs, :severity)),
      scope: parse_atom(fetch(attrs, :scope)) || :framework,
      description: fetch(attrs, :description),
      status: parse_atom(fetch(attrs, :status)) || :incoming,
      category: parse_atom(fetch(attrs, :category)),
      resolution: fetch(attrs, :resolution),
      source: fetch(attrs, :source) || default_source,
      story_id: fetch(attrs, :story_id),
      source_path: fetch(attrs, :source_path),
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp ensure_framework_table do
    case Process.get(@framework_table_key) do
      nil ->
        table = :ets.new(:issues_remote_stub_framework, [:set, :private])
        Process.put(@framework_table_key, table)
        table

      table ->
        table
    end
  end

  defp ensure_remote_table do
    case Process.get(@remote_table_key) do
      nil ->
        table = :ets.new(:issues_remote_stub_remote, [:set, :private])
        Process.put(@remote_table_key, table)
        table

      table ->
        table
    end
  end

  defp ensure_update_calls_table do
    case Process.get(@update_calls_key) do
      nil ->
        table = :ets.new(:issues_remote_stub_update_calls, [:bag, :private])
        Process.put(@update_calls_key, table)
        table

      table ->
        table
    end
  end

  defp remote_insert(%Issue{id: id} = issue) do
    table = ensure_remote_table()
    :ets.insert(table, {id, issue})
    :ok
  end

  defp framework_insert(%Issue{id: id} = issue) do
    table = ensure_framework_table()
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
