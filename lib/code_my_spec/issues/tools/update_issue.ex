defmodule CodeMySpec.Issues.Tools.UpdateIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "update_issue"

  @impl true
  def description do
    """
    Update non-status fields on an existing issue.

    Use this for re-triage decisions that don't change the issue's
    status — most commonly severity adjustments after a closer look
    at the body, or moving an issue under the right story / category
    after the original report misclassified it.

    Status transitions (incoming → accepted / dismissed, accepted →
    resolved) go through the dedicated `accept_issue` / `dismiss_issue`
    / `resolve_issue` tools — those flows enforce transition rules
    this tool deliberately skips.

    Allowed fields: `severity`, `story_number`, `category`, `source_path`,
    and `append`.

    ## Why `append` and not `description`

    An agent files an issue at the moment it has the evidence, which is
    often before it understands the defect — and that is the right time
    to file, because the evidence is perishable. So reports go stale,
    and until now the only remedy was another issue: `1f60a145` cited
    `server.log` for a stop hook that posts to :4004 and logs to
    `web.log`, which sent its reader to a process that was not involved
    and a log showing no activity. Correcting it took a second issue,
    `b0486568`, and the queue then held two reports of one defect with
    the first still misleading whoever picked it up.

    This appends rather than replacing, because issue bodies are written
    by whichever agent was there and a later reader needs to see what
    was originally claimed as well as what turned out to be true. A
    correction that quietly rewrites the first account destroys the one
    thing that makes the sequence legible.

    Status transitions still go through `accept_issue` / `dismiss_issue`
    / `resolve_issue`.
    """
  end

  @impl true
  def params do
    %{
      append:
        {:meta, :string,
         [
           description:
             "Add a correction or later evidence to the end of the issue body. The original text is kept — use this instead of filing a second issue to correct a first."
         ]},
      category:
        {:meta, :string,
         [description: "Re-categorize: 'bug' or 'requirements_change' (those two only)"]},
      severity:
        {:meta, :string, [description: "New severity: critical, high, medium, low, or info"]},
      source_path: {:meta, :string, [description: "Update the source file path"]},
      story_number:
        {:meta, :integer, [description: "Re-link the issue to the story with this number"]},
      issue_id: {:required, {:meta, :string, [description: "Issue ID to update"]}},
      detach_from_story:
        {:meta, :boolean,
         [
           description:
             "Detach the issue from whatever story it is on, leaving it unattributed. For a report that reached the wrong story — `Issues.attribute_to_story/3` sweeps unattributed :app issues onto whichever story's QA attempt is being submitted, so an infrastructure failure can end up gating a feature story. Sometimes the right story is none."
         ]}
    }
  end

  # The re-triage levers, which are product's.
  #
  # `append` is deliberately not here: it only ever adds, and the roles that
  # discover a report has gone stale are the ones working it (`0074e1b8`). The
  # fields below are the accept/dismiss decision under another name, so a caller
  # who does not carry the triage authority is refused them.
  @triage_fields [
    {:severity, "severity"},
    {:story_number, "story_number"},
    {:detach_from_story, "detach_from_story"},
    {:category, "category"},
    {:source_path, "source_path"}
  ]

  @impl true
  def call(params, context) do
    with {:ok, attrs} <- build_attrs(params),
         {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         :ok <- ensure_some_field(attrs, params[:append]),
         :ok <- ensure_may_triage(scope, context, params),
         {:ok, attrs} <- StoryRefs.put_story_id(scope, attrs),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         attrs = maybe_append(attrs, issue, params[:append]),
         {:ok, updated} <- Issues.update_issue(scope, issue, attrs) do
      release_if_downgraded(scope, issue, updated)
      IssuesMapper.issue_updated_response(updated, "updated")
    else
      :empty ->
        IssuesMapper.error(
          "No updatable fields provided. Pass at least one of: severity, story_number, " <>
            "detach_from_story, category, source_path, append."
        )

      nil ->
        IssuesMapper.not_found_error()

      {:error, %Ecto.Changeset{} = cs} ->
        IssuesMapper.validation_error(cs)

      {:error, reason} ->
        IssuesMapper.error(reason)
    end
  end

  # Refuses the triage fields to a role that does not carry them, and lets
  # `append` through.
  #
  # The role comes from the agent on the connection (`AgentScope`), never from
  # an argument: an argument is not where authority comes from. A caller with
  # no agent at all -- a person, an operator session -- keeps the whole tool,
  # which is what every other tool in this server assumes.
  defp ensure_may_triage(scope, context, params) do
    case role_of(scope, context) do
      :product -> :ok
      :unscoped -> :ok
      role -> refuse_or_allow(role, params)
    end
  end

  defp refuse_or_allow(role, params) do
    case Enum.filter(@triage_fields, fn {key, _} -> provided?(params[key]) end) do
      [] ->
        :ok

      named ->
        {:error,
         "Re-triaging an issue (#{Enum.map_join(named, ", ", &elem(&1, 1))}) is product's call; " <>
           "a #{role} agent carries only `append`. Append the evidence and, if the triage " <>
           "is wrong, say so in the append so product can act on it."}
    end
  end

  # `detach_from_story` is a boolean and only means anything as `true`, so the
  # binary `present?/1` above would let it through as "not provided".
  defp provided?(true), do: true
  defp provided?(value), do: present?(value)

  defp role_of(scope, context) do
    with agent_id when is_binary(agent_id) <- context[:agent_id],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id) do
      agent.role
    else
      _ -> :unscoped
    end
  end

  # A task blocked on this issue waits for a fix; below the fix threshold none
  # is ever offered, so a downgrade past it would wedge the waiter.
  defp release_if_downgraded(scope, before, updated) do
    threshold = Configurations.fix_issues_min_severity(scope)

    if Issue.blocking?(before, threshold) and not Issue.blocking?(updated, threshold),
      do: TaskOwner.issue_below_threshold(updated.id, threshold)
  end

  # Refusing an unrecognised value rather than dropping it.
  #
  # `parse_severity/1` and `parse_category/1` both answered `nil` for anything
  # they did not recognise, `maybe_put/3` then dropped the key, and the call
  # replied "updated" having changed nothing. Measured 2026-09-23:
  # `update_issue({category: "devops"})` returned success twice while the row was
  # untouched, and it took reading `parse_category/1` to find out why. The
  # vocabulary being small is fine; a write that reports success without writing
  # is not.
  defp build_attrs(params) do
    with {:ok, attrs} <- put_parsed(%{}, :severity, params[:severity], &parse_severity/1),
         {:ok, attrs} <- put_parsed(attrs, :category, params[:category], &parse_category/1) do
      attrs =
        attrs
        |> maybe_put(:story_number, params[:story_number])
        |> maybe_put(:source_path, params[:source_path])
        |> maybe_detach(params[:detach_from_story])

      {:ok, attrs}
    end
  end

  defp put_parsed(attrs, _key, nil, _parse), do: {:ok, attrs}

  defp put_parsed(attrs, key, raw, parse) do
    case parse.(raw) do
      nil -> {:error, refusal(key, raw)}
      parsed -> {:ok, Map.put(attrs, key, parsed)}
    end
  end

  defp refusal(:severity, raw),
    do: "#{inspect(raw)} is not a severity. Use one of: critical, high, medium, low, info."

  defp refusal(:category, raw),
    do: "#{inspect(raw)} is not a category. Use one of: bug, requirements_change."

  # Explicit rather than `story_number: null`, which is not expressible from a Lua
  # table — `story_number = nil` removes the key and reads as "not provided", so the
  # call reported success and left the attribution alone.
  defp maybe_detach(attrs, true), do: Map.put(attrs, :story_id, nil)
  defp maybe_detach(attrs, _not_true), do: attrs

  defp ensure_some_field(attrs, append) do
    if map_size(attrs) > 0 or present?(append), do: :ok, else: :empty
  end

  # Under a rule rather than at the end of the body, so a reader can see at a
  # glance that what follows was not part of the original report. Kept in the
  # same field because that is what every consumer already reads — a separate
  # corrections table would leave `list_issues` and the triage prompt showing
  # the uncorrected text, which is the failure this is fixing.
  defp maybe_append(attrs, issue, append) do
    if present?(append) do
      stamped = """
      #{issue.description}

      ---

      **Correction / later evidence — #{DateTime.utc_now() |> DateTime.to_iso8601()}**

      #{String.trim(append)}
      """

      Map.put(attrs, :description, stamped)
    else
      attrs
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_severity(nil), do: nil

  defp parse_severity(value) when is_binary(value) do
    case String.downcase(value) do
      sev when sev in ~w(critical high medium low info) -> String.to_atom(sev)
      _ -> nil
    end
  end

  defp parse_category(nil), do: nil
  defp parse_category("bug"), do: :bug
  defp parse_category("requirements_change"), do: :requirements_change
  defp parse_category(other) when is_atom(other), do: other
  defp parse_category(_), do: nil
end
