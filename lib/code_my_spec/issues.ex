defmodule CodeMySpec.Issues do
  @moduledoc """
  The Issues context.

  Database is the source of truth. Markdown files in `.code_my_spec/issues/`
  are read-only projections for agent consumption. Issues are created by evaluate
  hooks (from QA results and braindump triage), never by agents directly.
  """

  alias CodeMySpec.Documents.QaIssue
  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Issues.Projector
  alias CodeMySpec.Users.Scope

  # -- Reads ------------------------------------------------------------------

  def list_issues(%Scope{} = scope), do: IssuesRepository.list_issues(scope)

  def list_by_status(%Scope{} = scope, status), do: IssuesRepository.list_by_status(scope, status)

  def list_by_story(%Scope{} = scope, story_id), do: IssuesRepository.list_by_story(scope, story_id)

  def get_issue!(%Scope{} = scope, id), do: IssuesRepository.get_issue!(scope, id)

  # -- Create -----------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs) do
    with {:ok, issue} <- IssuesRepository.create_issue(scope, attrs) do
      Projector.project_issue(scope.environment, issue)
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
          {:ok, issue} ->
            Projector.project_issue(scope.environment, issue)
            issue

          {:error, _} ->
            nil
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

    with {:ok, issue} <- IssuesRepository.create_issue(scope, merged) do
      Projector.project_issue(scope.environment, issue)
      {:ok, issue}
    end
  end

  # -- Status transitions -----------------------------------------------------

  def accept_issue(%Scope{} = scope, %Issue{} = issue) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :accepted) do
      Projector.project_issue(scope.environment, issue)
      {:ok, issue}
    end
  end

  def dismiss_issue(%Scope{} = scope, %Issue{} = issue, reason) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :dismissed, reason) do
      Projector.remove_projection(scope.environment, issue)
      {:ok, issue}
    end
  end

  def resolve_issue(%Scope{} = scope, %Issue{} = issue, resolution) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :resolved, resolution) do
      Projector.project_issue(scope.environment, issue)
      {:ok, issue}
    end
  end

  # -- Projection -------------------------------------------------------------

  @doc "Re-project all active issues to filesystem. Idempotent."
  def project_all(%Scope{} = scope) do
    issues = IssuesRepository.list_issues(scope)
    Projector.project_all(scope.environment, issues)
  end

  # -- Triage reconciliation --------------------------------------------------

  @doc """
  Reconciles filesystem triage state back to the database.

  The triage agent moves projected files between incoming/ and accepted/ directories.
  This function checks each :incoming issue in the DB and updates its status based
  on where the agent moved its projected file:

  - File still in incoming/ → no change
  - File moved to accepted/ → accept the issue
  - File removed from incoming/ → dismiss the issue
  """
  def reconcile_triage(%Scope{} = scope) do
    incoming = IssuesRepository.list_by_status(scope, :incoming)
    env = scope.environment

    Enum.each(incoming, fn issue ->
      filename = Projector.build_filename(issue)
      incoming_path = Path.join(Paths.issues_incoming_dir(), filename)
      accepted_path = Path.join(Paths.issues_accepted_dir(), filename)

      cond do
        Environments.file_exists?(env, incoming_path) ->
          :noop

        Environments.file_exists?(env, accepted_path) ->
          accept_issue(scope, issue)

        true ->
          dismiss_issue(scope, issue, "Dismissed during triage")
      end
    end)

    :ok
  end

  @doc """
  Reconciles agent-written resolutions from projected files back to the database.

  The fix-issues agent adds `## Resolution` sections to projected issue files.
  This function reads each :accepted issue's projected file and, if a resolution
  section is found, transitions the issue to :resolved in the database.
  """
  def reconcile_resolutions(%Scope{} = scope) do
    accepted = IssuesRepository.list_by_status(scope, :accepted)
    env = scope.environment

    Enum.each(accepted, fn issue ->
      filename = Projector.build_filename(issue)
      path = Path.join(Paths.issues_accepted_dir(), filename)

      with {:ok, content} <- Environments.read_file(env, path),
           {:ok, resolution} <- extract_resolution(content) do
        resolve_issue(scope, issue, resolution)
      end
    end)

    :ok
  end

  @doc "Returns the projected filename for an issue."
  def projected_filename(%Issue{} = issue), do: Projector.build_filename(issue)

  @doc "Returns the projected file path for an issue based on its current status."
  def projected_path(%Issue{} = issue) do
    dir =
      case issue.status do
        :incoming -> Paths.issues_incoming_dir()
        _ -> Paths.issues_accepted_dir()
      end

    Path.join(dir, Projector.build_filename(issue))
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

  defp extract_resolution(content) do
    case Regex.run(~r/^## Resolution\s*\n([\s\S]*?)(?=\n## |\z)/m, content) do
      [_, text] ->
        trimmed = String.trim(text)
        if trimmed == "", do: :error, else: {:ok, trimmed}

      _ ->
        :error
    end
  end

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
end
