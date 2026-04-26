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
  alias CodeMySpec.Users.Scope

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
    with {:ok, issue} <- IssuesRepository.update_status(issue, :accepted, nil, opts) do
      broadcast(scope, {:accepted, issue})
      {:ok, issue}
    end
  end

  def dismiss_issue(%Scope{} = scope, %Issue{} = issue, reason) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :dismissed, reason) do
      broadcast(scope, {:dismissed, issue})
      {:ok, issue}
    end
  end

  def resolve_issue(%Scope{} = scope, %Issue{} = issue, resolution) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :resolved, resolution) do
      broadcast(scope, {:resolved, issue})
      sync_resolution_to_remote(scope, issue)
      {:ok, issue}
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

  defp sync_resolution_to_remote(scope, %Issue{} = issue) do
    alias CodeMySpec.Issues.RemoteClient

    Task.start(fn ->
      RemoteClient.update_issue(scope, issue.id, %{
        status: "resolved",
        resolution: issue.resolution
      })
    end)
  end
end
