defmodule CodeMySpec.Issues do
  @moduledoc """
  The Issues context.

  Database is the source of truth. Markdown files in `.code_my_spec/issues/`
  are read-only projections for agent consumption. Issues are created by evaluate
  hooks (from QA results and braindump triage), never by agents directly.
  """

  alias CodeMySpec.Documents.QaIssue
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Issues.RemoteClient
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the configured remote-issues client module.

  In production this is `CodeMySpec.Issues.RemoteClient` (real HTTP to
  the CodeMySpec server). In tests it is swapped via
  `:code_my_spec, :issues_remote_client` to the in-process stub so
  spex can drive framework-scope operations without outbound HTTP.

  The MCP Issues tools call this when routing `scope: framework`
  operations — framework issues live on the server, never in the
  local CLI's DB.
  """
  def remote_client do
    Application.get_env(:code_my_spec, :issues_remote_client, RemoteClient)
  end

  # -- Reads ------------------------------------------------------------------

  def list_issues(%Scope{} = scope), do: IssuesRepository.list_issues(scope)

  def list_by_status(%Scope{} = scope, status), do: IssuesRepository.list_by_status(scope, status)

  def list_by_story(%Scope{} = scope, story_id), do: IssuesRepository.list_by_story(scope, story_id)

  def get_issue(%Scope{} = scope, id), do: IssuesRepository.get_issue(scope, id)

  def get_issue!(%Scope{} = scope, id), do: IssuesRepository.get_issue!(scope, id)

  def list_filtered(%Scope{} = scope, filters), do: IssuesRepository.list_filtered(scope, filters)

  # -- Create -----------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs) do
    with {:ok, issue} <- IssuesRepository.create_issue(scope, attrs) do
      broadcast(scope, {:created, issue})
      {:ok, issue}
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

        case IssuesRepository.upsert_issue(scope, attrs) do
          {:ok, issue, _status} -> issue
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

    IssuesRepository.create_issue(scope, merged)
  end

  # -- Status transitions -----------------------------------------------------

  def accept_issue(%Scope{} = scope, %Issue{} = issue, opts \\ []) do
    with :ok <- sync_disposition_to_remote(scope, issue, :accepted, opts),
         {:ok, issue} <- IssuesRepository.update_status(issue, :accepted, nil, opts) do
      broadcast(scope, {:accepted, issue})
      {:ok, issue}
    end
  end

  def dismiss_issue(%Scope{} = scope, %Issue{} = issue, reason) do
    opts = [resolution: reason]

    with :ok <- sync_disposition_to_remote(scope, issue, :dismissed, opts),
         {:ok, issue} <- IssuesRepository.update_status(issue, :dismissed, reason) do
      broadcast(scope, {:dismissed, issue})
      {:ok, issue}
    end
  end

  def resolve_issue(%Scope{} = scope, %Issue{} = issue, resolution) do
    opts = [resolution: resolution]

    with :ok <- sync_disposition_to_remote(scope, issue, :resolved, opts),
         {:ok, issue} <- IssuesRepository.update_status(issue, :resolved, resolution) do
      broadcast(scope, {:resolved, issue})
      {:ok, issue}
    end
  end

  @doc """
  Pulls all incoming issues from the remote server and upserts them
  into the local DB.

  Called at the start of every triage task so the local view reflects
  the server's current incoming set across every scope. Failure to
  reach the server returns `{:error, reason}` — triage callers fail
  loudly rather than degrading to local-only.
  """
  def pull_incoming_from_remote(%Scope{} = scope) do
    case remote_client().list_incoming_issues(scope) do
      {:ok, issues} ->
        Enum.each(issues, fn issue -> IssuesRepository.upsert_from_server(scope, issue) end)
        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Query helpers ----------------------------------------------------------

  def has_unresolved_issues?(%Scope{} = scope, min_severity \\ :medium) do
    IssuesRepository.count_by_status_and_min_severity(scope, :accepted, min_severity) > 0
  end

  def has_untriaged_issues?(%Scope{} = scope, min_severity \\ :medium) do
    IssuesRepository.count_by_status_and_min_severity(scope, :incoming, min_severity) > 0
  end

  # -- Private ----------------------------------------------------------------

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

  # Synchronously sync a local disposition (accept/dismiss/resolve)
  # back to the remote server when the issue is mirrored. Failure is
  # surfaced as `{:error, message}` so the caller can refuse to flip
  # the local state, keeping local and remote in lockstep. Local-only
  # issues (`synced_from_server` is false/nil) bypass the sync.
  defp sync_disposition_to_remote(_scope, %Issue{synced_from_server: synced}, _status, _opts)
       when synced != true do
    :ok
  end

  defp sync_disposition_to_remote(scope, %Issue{} = issue, status, opts) do
    attrs = build_remote_attrs(status, opts)

    case remote_client().update_issue(scope, issue.id, attrs) do
      {:ok, _} ->
        :ok

      {:error, :not_authenticated} ->
        # The local CLI is unauthenticated against the remote. Treat
        # this as a hard failure rather than silently degrading — the
        # rule says fail loudly so the operator knows their local
        # disposition did NOT round-trip.
        {:error,
         "Cannot reach the issues server: not authenticated. Sign in and retry the disposition."}

      {:error, reason} ->
        {:error,
         "Cannot reach the issues server: #{inspect(reason)}. Retry when connectivity is restored."}
    end
  end

  defp build_remote_attrs(:accepted, opts) do
    %{status: "accepted"}
    |> maybe_put_attr(:category, Keyword.get(opts, :category))
    |> maybe_put_attr(:story_id, Keyword.get(opts, :story_id))
  end

  defp build_remote_attrs(:dismissed, opts) do
    %{status: "dismissed", resolution: Keyword.get(opts, :resolution)}
  end

  defp build_remote_attrs(:resolved, opts) do
    %{status: "resolved", resolution: Keyword.get(opts, :resolution)}
  end

  defp maybe_put_attr(map, _key, nil), do: map
  defp maybe_put_attr(map, key, value), do: Map.put(map, key, value)
end
