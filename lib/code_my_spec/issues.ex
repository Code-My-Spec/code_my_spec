defmodule CodeMySpec.Issues do
  @moduledoc """
  The Issues context.

  Issues live in whatever database this application is talking to, and
  every function here writes it directly.

  There used to be a second path: the CLI envs routed each call over HTTP
  to the server through `RemoteClient`, because the tools ran on a
  developer's machine and the rows lived elsewhere. The tools run on the
  server now — the harness forwards to them rather than reimplementing
  them — so "somewhere else" is gone and with it the reason to dispatch.
  The local application keeps its own issues, locally, and does not
  replicate or sync anybody else's.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  # -- Reads ------------------------------------------------------------------

  def list_issues(%Scope{} = scope) do
    IssuesRepository.list_issues(scope)
  end

  def list_by_status(%Scope{} = scope, status) do
    IssuesRepository.list_by_status(scope, status)
  end

  @doc """
  Whether this project already has an unfinished issue with exactly this title.

  See `IssuesRepository.open_issue_titled?/2`. Exposed because the fault paths
  in `MainAgent` file by a title built from the fault, and a fault that persists
  is reported by every call that notices it.

  Unfinished means anything but `:resolved` — a dismissed fault recurring is
  still not worth acting on, a resolved one recurring is a regression. The
  repository's doc has the reasoning.
  """
  @spec open_issue_titled?(Scope.t(), String.t()) :: boolean()
  def open_issue_titled?(%Scope{} = scope, title),
    do: IssuesRepository.open_issue_titled?(scope, title)

  def list_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    IssuesRepository.list_by_status_and_min_severity(scope, status, min_severity)
  end

  def list_by_story(%Scope{} = scope, story_id) do
    IssuesRepository.list_by_story(scope, story_id)
  end

  @doc """
  Issues attributed to one story, at a status, at or above a severity.

  What gates a single story's release, as opposed to
  `list_by_status_and_min_severity/3`, which answers for the whole project.
  """
  def list_by_story_status_and_min_severity(%Scope{} = scope, story_id, status, min_severity) do
    IssuesRepository.list_by_story_status_and_min_severity(scope, story_id, status, min_severity)
  end

  @doc """
  Attribute unattributed `:app` issues to a story. Returns the count updated.

  Called when a QA attempt is submitted: the agent has just named these
  issues as the findings of a pass over one story, and `story_issues_resolved`
  reads `story_id` to decide what blocks that story's release. Leaving it to
  the agent to pass `story_id` on every `create_issue` call did not work —
  every accepted issue on this project reached triage unattributed.
  """
  def attribute_to_story(%Scope{} = scope, issue_ids, story_id)
      when is_list(issue_ids) and not is_nil(story_id) do
    IssuesRepository.attribute_to_story(scope, issue_ids, story_id)
  end

  def attribute_to_story(_scope, _issue_ids, _story_id), do: 0

  def get_issue(%Scope{} = scope, id) do
    IssuesRepository.get_issue(scope, id)
  end

  @doc """
  Every framework-scoped issue across every project, for the vendor.

  See `CodeMySpec.Issues.IssuesRepository.list_framework_issues/1` — framework
  issues live in the project that filed them, and this is the one place that
  crosses a boundary to collect them.
  """
  defdelegate list_framework_issues(scope), to: IssuesRepository

  @doc """
  An issue by full id or unique prefix — `{:ok, issue} | :not_found | {:ambiguous, ids}`.

  See `CodeMySpec.Issues.IssuesRepository.fetch_issue/2`. Use this over
  `get_issue/2` wherever the answer is shown to somebody, so an ambiguous prefix
  can say so instead of being reported as a missing issue.
  """
  defdelegate fetch_issue(scope, id), to: IssuesRepository

  def get_issue!(%Scope{} = scope, id) do
    IssuesRepository.get_issue!(scope, id)
  end

  defdelegate unresolved_by_story(scope, min_severity), to: IssuesRepository

  def list_filtered(%Scope{} = scope, filters) do
    IssuesRepository.list_filtered(scope, filters)
  end

  # -- Create -----------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs) do
    with {:ok, issue} <- IssuesRepository.create_issue(scope, attrs) do
      broadcast(scope, {:created, issue})

      {:ok, issue}
    end
  end

  @doc """
  Widget-side issue report: an end-user of a client app files an issue through
  the support widget, authenticated at the socket by the project's deploy key
  (server-to-server — no CMS user `Scope`). Mirrors `create_issue/2` but takes
  the account/project ids directly, stamps `source: "widget"` and `scope: :app`
  unless overridden, and broadcasts `{:created, issue}` so local mirrors and the
  operator dashboard pick it up like any other issue.

  `attrs` are string-keyed (title/description/severity from the widget form).
  """
  def report_from_widget(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("source", "widget")
      |> Map.put_new("scope", "app")

    create_issue(scope, attrs)
  end

  @doc """
  Deploy-key-authenticated framework issue report for clients with no OAuth
  session (widget-style embeds and other external reporters) — the deploy key
  resolves the project via its blind-index hash, same flow as
  `report_from_widget/3`. Scope is forced to `framework` so the key grants
  nothing broader. Installed CLIs don't take this path; they file framework
  issues over their OAuth session via `ProjectScopeOverride`.
  """
  def report_framework_issue(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("scope", "framework")
      |> Map.put_new("source", "cli")

    create_issue(scope, attrs)
  end

  @doc """
  Report an issue from an end user of a generated app.

  The deploy key identifies the *project*; the person reporting is not
  authenticated and is not expected to be. That is the whole point — someone
  hitting a bug in a shipped app has no CodeMySpec account and should not need
  one to say so.

  Before this, the feedback widget filed through the OAuth path, so a generated
  project could not accept feedback until its owner had generated client
  credentials and set `CODEMYSPEC_CLIENT_ID` / `CODEMYSPEC_CLIENT_SECRET`. Two
  QA drills reported the widget rendering fine and failing only on submit, which
  is the worst shape for that failure: it looks like it works.

  Scoped `"app"`, not `"framework"` — this is feedback about the generated app,
  not about CodeMySpec.
  """
  @spec report_widget_issue(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def report_widget_issue(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("scope", "app")
      |> Map.put_new("source", "widget")
      |> Map.put_new("severity", "medium")

    create_issue(scope, attrs)
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
      |> Enum.filter(&fileable?/1)
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

  # Whether a parsed QA-result issue has a severity this domain recognizes at
  # all, not whether its severity is any *particular* one -- that judgment
  # belongs to `parse_severity/1`, which defaults an unrecognized string to
  # `:medium` rather than reject. The two must not agree: `parse_severity/1`
  # never fails, so nothing else stops an issue with a garbled severity field
  # from being filed. This is the one check upstream of it.
  #
  # Moved here from `Documents.QaIssue.fileable?/1` (formerly a boundary
  # cycle: Documents depended on Issues.Issue for its own `@scopes`, and
  # Issues depended back on Documents.QaIssue just for this predicate).
  # Written against a plain value's `.severity` field rather than pattern-
  # matched against the `QaIssue` struct, so any caller can pass a QaIssue
  # (or anything else shaped like one) without Issues needing to know the
  # struct exists.
  @fileable_severities ~w(critical high medium low info)

  @spec fileable?(%{severity: String.t()}) :: boolean()
  def fileable?(%{severity: s}) when s in @fileable_severities, do: true
  def fileable?(_), do: false

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
      {:ok, issue}
    end
  end

  @doc """
  Update non-status fields on an existing issue (severity, story_id,
  category, source_path). Status transitions go through
  `accept_issue` / `dismiss_issue` / `resolve_issue` — this is the
  catch-all for everything else.
  """
  def update_issue(%Scope{} = scope, %Issue{} = issue, attrs) do
    with {:ok, updated} <- IssuesRepository.update_attributes(issue, attrs) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
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

  defp upsert_or_create(scope, attrs) do
    case IssuesRepository.upsert_issue(scope, attrs) do
      {:ok, issue, _status} -> {:ok, issue}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp broadcast(%Scope{active_account_id: account_id} = scope, message)
       when is_binary(account_id) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{account_id}:issues", message)

    # And to the graph's own topic, additionally: `GraphWatcher` debounces these
    # and asks the fingerprint whether anything really moved. An incoming issue
    # makes `issues_triaged` actionable, which is work appearing that no reader
    # would notice. See `Requirements.GraphInputs`.
    # The event, not an invalidation. `Requirements.Handlers` settles the three
    # issue requirements from it directly; `graph_entities/1` rides along so a
    # consumer with no handler still has something to invalidate.
    GraphInputs.event(
      scope,
      "Issues",
      event_kind(message),
      event_payload(message),
      graph_entities(message)
    )
  end

  defp event_kind({:created, _}), do: "issue_created"
  defp event_kind({:accepted, _}), do: "issue_accepted"
  defp event_kind({:dismissed, _}), do: "issue_dismissed"
  defp event_kind({:resolved, _}), do: "issue_resolved"
  defp event_kind({:updated, _}), do: "issue_updated"
  defp event_kind(_), do: "issue_changed"

  defp event_payload({_verb, %{} = issue}),
    do: %{
      "id" => issue.id,
      "severity" => issue.severity && to_string(issue.severity),
      "status" => issue.status && to_string(issue.status),
      "story_id" => Map.get(issue, :story_id)
    }

  defp event_payload(_message), do: %{}

  defp broadcast(_scope, _message), do: :ok

  # The story it was attributed to, if any, and always the project.
  #
  # `:project` unconditionally, because `issues_triaged` and `issues_resolved`
  # are project requirements and read the whole queue — an issue arriving or
  # being resolved moves them whether or not it names a story.
  #
  # The story only when QA attributed one. `IssuesChecker.story_resolved?/2`
  # draws that line itself — "an issue with no `story_id` is the project queue's
  # problem, not this story's" — and `Freshness.story/2` hashes
  # `issues_by_story` on the same basis, so an unattributed issue belongs to no
  # story's requirements and naming one would recompute it for nothing.
  defp graph_entities({_verb, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}, :project]

  defp graph_entities(_message), do: [:project]
end
