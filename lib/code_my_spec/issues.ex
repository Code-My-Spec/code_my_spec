defmodule CodeMySpec.Issues do
  @moduledoc """
  The Issues context.

  Issues are homed on the server (`:dev` / `:prod` Phoenix endpoints,
  backed by Postgres). The CLI envs (`:dev_cli` / `:prod_cli`) never
  read or write the local SQLite issues table — every public function
  dispatches by env and routes CLI calls through `RemoteClient` HTTP
  to the server. The server stays the single source of truth.

  Test (`:test`) keeps the local Repo path so fixtures and spex can
  drive issues through the in-memory DB without a network round-trip.
  """

  alias CodeMySpec.Documents.QaIssue
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Issues.RemoteClient
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the configured remote-issues client module.

  Production binds `CodeMySpec.Issues.RemoteClient`. Tests swap via
  `:code_my_spec, :issues_remote_client` to drive against a stub — but
  tests run in `:test` env which uses the local Repo path, so the stub
  is only exercised for the small set of tests that explicitly hit
  remote-client code (validation_error / network-error branches).
  """
  def remote_client do
    Application.get_env(:code_my_spec, :issues_remote_client, RemoteClient)
  end

  # Routing predicate. true → use the local Repo (server is the source
  # of truth and we ARE the server, OR we're in test); false → use
  # RemoteClient HTTP to the server.
  defp local_repo_env? do
    not Application.get_env(:code_my_spec, :sync_issues_to_muster, false)
  end

  # -- Reads ------------------------------------------------------------------

  def list_issues(%Scope{} = scope) do
    if local_repo_env?(),
      do: IssuesRepository.list_issues(scope),
      else: remote_list!(scope, %{})
  end

  def list_by_status(%Scope{} = scope, status) do
    if local_repo_env?(),
      do: IssuesRepository.list_by_status(scope, status),
      else: remote_list!(scope, %{status: status})
  end

  def list_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    if local_repo_env?() do
      IssuesRepository.list_by_status_and_min_severity(scope, status, min_severity)
    else
      # Server's IssuesController.build_filters/1 doesn't expose
      # min_severity directly. Fetch by status and filter client-side.
      scope
      |> remote_list!(%{status: status})
      |> Enum.filter(&(severity_rank(&1.severity) >= severity_rank(min_severity)))
    end
  end

  def list_by_story(%Scope{} = scope, story_id) do
    if local_repo_env?(),
      do: IssuesRepository.list_by_story(scope, story_id),
      else: remote_list!(scope, %{story_id: story_id})
  end

  def get_issue(%Scope{} = scope, id) do
    if local_repo_env?() do
      IssuesRepository.get_issue(scope, id)
    else
      case remote_client().get_issue(scope, id) do
        {:ok, issue} -> issue
        {:error, :not_found} -> nil
        {:error, _} -> nil
      end
    end
  end

  def get_issue!(%Scope{} = scope, id) do
    if local_repo_env?() do
      IssuesRepository.get_issue!(scope, id)
    else
      case remote_client().get_issue(scope, id) do
        {:ok, issue} -> issue
        {:error, reason} -> raise "Issues.get_issue!: #{inspect(reason)}"
      end
    end
  end

  def list_filtered(%Scope{} = scope, filters) do
    if local_repo_env?(),
      do: IssuesRepository.list_filtered(scope, filters),
      else: remote_list!(scope, filters)
  end

  # -- Create -----------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs) do
    if local_repo_env?() do
      with {:ok, issue} <- IssuesRepository.create_issue(scope, attrs) do
        broadcast(scope, {:created, issue})
        {:ok, issue}
      end
    else
      with {:ok, issue} <- remote_client().create_issue(scope, attrs) do
        broadcast(scope, {:created, issue})
        {:ok, issue}
      end
    end
  end

  @doc """
  Creates issues from a validated QA result document.

  Parses the issues section, upserts each issue (skipping duplicates by title + story_id),
  and projects all created issues to the filesystem.
  """
  def create_from_qa_result(%Scope{} = scope, story_id, document) do
    issues = Map.get(document.sections, "issues", [])

    created =
      issues
      |> Enum.filter(&QaIssue.fileable?/1)
      |> Enum.map(fn qa_issue ->
        attrs = %{
          title: qa_issue.title,
          severity: parse_severity(qa_issue.severity),
          scope: parse_scope(qa_issue.scope),
          description: qa_issue.description,
          story_id: story_id,
          source_path: ".code_my_spec/qa/#{story_id}/result.md"
        }

        case upsert_or_create(scope, attrs) do
          {:ok, issue} -> issue
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, created}
  end

  @doc """
  Creates an issue from a braindump markdown file.

  Braindump issues default to :accepted status and :medium severity.
  """
  def create_from_braindump(%Scope{} = scope, content, attrs \\ %{}) do
    {title, description} = parse_braindump(content)

    merged =
      Map.merge(
        %{
          title: title,
          description: description,
          severity: :medium,
          scope: :app,
          status: :accepted
        },
        attrs
      )

    if local_repo_env?() do
      IssuesRepository.create_issue(scope, merged)
    else
      remote_client().create_issue(scope, merged)
    end
  end

  # -- Status transitions -----------------------------------------------------

  def accept_issue(%Scope{} = scope, %Issue{} = issue, opts \\ []) do
    if local_repo_env?() do
      with {:ok, issue} <- IssuesRepository.update_status(issue, :accepted, nil, opts) do
        broadcast(scope, {:accepted, issue})
        {:ok, issue}
      end
    else
      attrs =
        %{status: "accepted"}
        |> maybe_put_attr(:category, Keyword.get(opts, :category))
        |> maybe_put_attr(:story_id, Keyword.get(opts, :story_id))

      with {:ok, issue} <- remote_client().update_issue(scope, issue.id, attrs) do
        broadcast(scope, {:accepted, issue})
        {:ok, issue}
      end
    end
  end

  def dismiss_issue(%Scope{} = scope, %Issue{} = issue, reason) do
    if local_repo_env?() do
      with {:ok, issue} <- IssuesRepository.update_status(issue, :dismissed, reason) do
        broadcast(scope, {:dismissed, issue})
        {:ok, issue}
      end
    else
      with {:ok, issue} <-
             remote_client().update_issue(scope, issue.id, %{
               status: "dismissed",
               resolution: reason
             }) do
        broadcast(scope, {:dismissed, issue})
        {:ok, issue}
      end
    end
  end

  def resolve_issue(%Scope{} = scope, %Issue{} = issue, resolution) do
    if local_repo_env?() do
      with {:ok, issue} <- IssuesRepository.update_status(issue, :resolved, resolution) do
        broadcast(scope, {:resolved, issue})
        {:ok, issue}
      end
    else
      with {:ok, issue} <-
             remote_client().update_issue(scope, issue.id, %{
               status: "resolved",
               resolution: resolution
             }) do
        broadcast(scope, {:resolved, issue})
        {:ok, issue}
      end
    end
  end

  @doc """
  Update non-status fields on an existing issue (severity, story_id,
  category, source_path). Status transitions go through
  `accept_issue` / `dismiss_issue` / `resolve_issue` — this is the
  catch-all for everything else.
  """
  def update_issue(%Scope{} = scope, %Issue{} = issue, attrs) do
    if local_repo_env?() do
      with {:ok, updated} <- IssuesRepository.update_attributes(issue, attrs) do
        broadcast(scope, {:updated, updated})
        {:ok, updated}
      end
    else
      with {:ok, updated} <- remote_client().update_issue(scope, issue.id, attrs) do
        broadcast(scope, {:updated, updated})
        {:ok, updated}
      end
    end
  end

  # -- Query helpers ----------------------------------------------------------

  def has_unresolved_issues?(%Scope{} = scope, min_severity \\ :medium) do
    if local_repo_env?() do
      IssuesRepository.count_by_status_and_min_severity(scope, :accepted, min_severity) > 0
    else
      list_by_status_and_min_severity(scope, :accepted, min_severity) != []
    end
  end

  def has_untriaged_issues?(%Scope{} = scope, min_severity \\ :medium) do
    if local_repo_env?() do
      IssuesRepository.count_by_status_and_min_severity(scope, :incoming, min_severity) > 0
    else
      list_by_status_and_min_severity(scope, :incoming, min_severity) != []
    end
  end

  # -- Private ----------------------------------------------------------------

  defp remote_list!(scope, filters) do
    case remote_client().list_issues(scope, filters) do
      {:ok, issues} -> issues
      {:error, _} -> []
    end
  end

  defp upsert_or_create(scope, attrs) do
    if local_repo_env?() do
      case IssuesRepository.upsert_issue(scope, attrs) do
        {:ok, issue, _status} -> {:ok, issue}
        {:error, reason} -> {:error, reason}
      end
    else
      # No upsert endpoint on the server — fall through to create_issue;
      # the server's create handles its own dedup if any.
      remote_client().create_issue(scope, attrs)
    end
  end

  defp severity_rank(:critical), do: 4
  defp severity_rank(:high), do: 3
  defp severity_rank(:medium), do: 2
  defp severity_rank(:low), do: 1
  defp severity_rank(:info), do: 0
  defp severity_rank(s) when is_binary(s), do: severity_rank(String.to_existing_atom(s))
  defp severity_rank(_), do: 0

  defp parse_severity(s) when is_atom(s), do: s

  defp parse_severity(s) when is_binary(s) do
    case String.downcase(s) do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      "info" -> :info
      _ -> :medium
    end
  end

  defp parse_scope(s) when is_atom(s), do: s

  defp parse_scope(s) when is_binary(s) do
    case String.downcase(s) do
      "app" -> :app
      "qa" -> :qa
      "docs" -> :docs
      "framework" -> :framework
      _ -> :app
    end
  end

  defp parse_scope(nil), do: :app

  defp parse_braindump(content) do
    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, title] ->
        description =
          content
          |> String.replace(~r/^#\s+.+\n*/, "")
          |> String.trim()

        {title, description}

      nil ->
        lines = String.split(content, "\n", parts: 2)
        title = List.first(lines) |> String.trim()
        description = Enum.at(lines, 1, "") |> String.trim()
        {title, description}
    end
  end

  def subscribe(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:issues")
  end

  defp broadcast(%Scope{active_account_id: account_id}, message) when is_binary(account_id) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{account_id}:issues", message)
  end

  defp broadcast(_scope, _message), do: :ok

  defp maybe_put_attr(map, _key, nil), do: map
  defp maybe_put_attr(map, key, value), do: Map.put(map, key, value)
end
