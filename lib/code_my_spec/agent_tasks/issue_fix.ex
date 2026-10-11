defmodule CodeMySpec.AgentTasks.IssueFix do
  @moduledoc """
  Fix the issue a working copy's team is bound to (story 1091).

  Completing this task certifies the copy for QA the way `ReadyForQa` does
  (John, 2026-10-11): trusting the coder's own report, with no check that it
  even compiles or its own regression passes, was an oversight in the design
  of this task rather than a deliberate choice. So completing it now runs the
  same procedure ready-for-QA runs (`Promotion.certify/3`, minus a story's own
  spex since an issue has none): a clean tree and a clean run of every
  analyzer at HEAD's exact commit.

    * Certified: the commit is stamped on the issue (`qa_ready_commit`, so QA
      tests that exact commit) and the fix hands to QA. This does not resolve
      the issue; a passing attempt through `submit_issue_qa_result` sends the
      coder to land the fix (`IssuePromote`), and the landing resolves it.
    * Pending (no clean run at HEAD yet): the gate starts the missing runs as
      its own, and the task stays open; each run answers the agent when it
      lands, as `ReadyForQa`'s do.
    * Refused (a dirty tree, or analyzer problems): the task stays open with
      the refusal as feedback.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Promotion

  def dispatch(_node) do
    "Fix the issue your team is bound to, then call `evaluate_task`. Completing it " <>
      "certifies the copy for QA the way ready-for-QA does — a clean tree and a " <>
      "clean run of every analyzer at HEAD — then hands the fix to QA. It does not " <>
      "resolve the issue."
  end

  @doc "Read the assigned issue and build the fix prompt. Returns `{:ok, prompt_text}`."
  def command(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil ->
        {:error, "Issue #{task.issue_id} no longer exists."}

      %{qa_ready_commit: commit} = issue when is_binary(commit) ->
        {:ok, already(issue, commit)}

      issue ->
        {:ok, build_prompt(scope, issue, task)}
    end
  end

  # Already certified — before this offer was made, or by a prior call that
  # certified but did not finish handing off (see `certified/3`). Nothing to
  # redo; completing again finishes the hand-off.
  defp already(issue, commit) do
    "Issue #{issue.id} is already certified ready for QA at #{commit}. There is " <>
      "nothing to do: complete this task with `evaluate_task`."
  end

  @doc "The stamp alone, certifying nothing. See the moduledoc."
  def evaluate(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil -> {:error, "Issue #{task.issue_id} no longer exists."}
      %{qa_ready_commit: commit} when is_binary(commit) -> {:ok, :valid}
      issue -> {:ok, :invalid, not_certified_yet(issue)}
    end
  end

  @doc """
  Complete the task: certify the copy at HEAD and hand the fix to QA. `owner`
  is who is completing it; an agent we run is answered when pending runs land.
  """
  def evaluate(scope, task, owner) do
    case Issues.get_issue(scope, task.issue_id) do
      nil ->
        {:error, "Issue #{task.issue_id} no longer exists."}

      %{qa_ready_commit: commit} = issue when is_binary(commit) ->
        hand_to_qa(scope, issue)

      issue ->
        scope |> Promotion.certify(nil, notify: agent_id(owner)) |> certified(scope, issue)
    end
  end

  # A clean certifying run stamps the issue, then hands it to QA — the same
  # turn this evaluates, so `Agents.IssueWork`'s very next read already offers
  # `qa_complete` instead of `fix_issue` again.
  defp certified({:ok, %{head: head}}, scope, issue) do
    with {:ok, stamped} <- Issues.set_qa_ready(scope, issue, head) do
      hand_to_qa(scope, stamped)
    end
  end

  defp certified({:pending, pending}, _scope, issue),
    do: {:ok, :pending, pending_text(pending, issue)}

  defp certified({:error, %{reason: reason}}, _scope, issue),
    do:
      {:ok, :invalid, "Issue #{issue.id} is not ready for QA: #{reason}\n\n" <> complete_again()}

  defp hand_to_qa(scope, issue) do
    with {:ok, _issue} <- Issues.set_awaiting_role(scope, issue, :qa), do: {:ok, :valid}
  end

  defp not_certified_yet(issue) do
    "Issue #{issue.id} is not certified for QA yet. " <> complete_again()
  end

  defp pending_text(%{commit: commit} = pending, issue) do
    sources = Enum.join(Map.get(pending, :started, []) ++ Map.get(pending, :running, []), ", ")

    "Issue #{issue.id} is not certified yet: analysis running at #{commit} " <>
      "(#{sources}). This task stays open. End your turn; you are told as each run " <>
      "lands. Then complete this task again (evaluate_task): if they are clean, " <>
      "#{commit} is stamped ready for QA and hands to QA; if not, fix what they " <>
      "found, commit, and complete again."
  end

  defp complete_again do
    "Fix it, commit, and complete this task again (evaluate_task). Completing it " <>
      "is the certification."
  end

  # As in `ReadyForQa`: `CodeMySpec.Agents` is not a dependency of this
  # boundary, and a session has no process to tell.
  defp agent_id(%{__struct__: CodeMySpec.Agents.Agent, id: id}), do: id
  defp agent_id(_owner), do: nil

  # In CodeMySpec's own project the framework is this repository: a coder told
  # framework defects "belong to the framework" tapped out every issue in its bag.
  defp framework_line(%{project_id: project_id}) do
    if project_id == Application.get_env(:code_my_spec, :code_my_spec_project_id),
      do: "framework defects are this repository's code, so fix them here.",
      else: "framework defects belong to the framework rather than an application workaround."
  end

  defp build_prompt(scope, issue, task) do
    """
    # Fix Issue #{issue.id}

    **#{issue.title}** [#{issue.severity}] — scope: #{issue.scope}

    #{issue.description}

    Work in the issue's scope: app defects change application code; QA defects
    repair the test tooling; docs defects correct documentation; #{framework_line(issue)}
    Add or repair regression coverage. Do not skip tests, mark them pending,
    or silence failures to make validation pass. Preserve the original behavior
    assertion unless product explicitly changes the requirement.

    Record the changed files, exact commit revision, fix evidence and validation
    results on this issue with `update_issue` before submitting it for QA.
    QA must be able to inspect what changed and what was verified.

    #{problems_section(Promotion.blocking_problems(scope))}

    Make the fix and commit it, then call `evaluate_task` with task_id "#{task.id}".
    Completing it checks that the tree is clean and that every analyzer has a \
    clean run at your HEAD, then certifies that commit and hands the fix to QA \
    at it — it does not resolve the issue. If a run at your HEAD is missing or \
    still running, completing starts it and the task stays open; end your turn \
    and complete again once you are told it landed. Once QA passes it you land \
    it on main through the promotion queue, and the landing resolves the issue.
    """
  end

  defp problems_section([]),
    do: "No problem that would block the certification is recorded on this copy right now."

  defp problems_section(problems) do
    "Problems on this copy that would block the certification (#{length(problems)}):\n\n" <>
      Promotion.describe_problems(problems)
  end
end
