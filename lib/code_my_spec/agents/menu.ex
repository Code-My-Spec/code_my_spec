defmodule CodeMySpec.Agents.Menu do
  @moduledoc """
  What to do next, said in the refusal.

  The stop hook's refusal says what to do instead, so an agent whose own area
  is clear does not have to guess.

  A **class** is countable state in this working copy that the hook can rank
  against other work; an **offer** is a line printed regardless, because the
  condition it serves cannot be detected or is not work here.

  ## The order

      1. task           evaluate_task          finish what you already started
      2. requirements   get_next_requirement

  Issues are not a class: the graph carries them per role
  (`issues_triaged`, `issues_resolved`). Neither are problems: they gate at
  promotion, so the menu only says how many there are (John, 2026-10-18).

  One directive leads; the rest are tallied as counts, so nothing starves
  invisibly.

  ## Offers

  Every refusal carries the open-question count with `list_user_questions` /
  `check_answer`, `ask_user_question`, and `semantic_search`; `tap_out` only
  inside the loop.

  See knowledge/agents/coordination, "The stop menu".
  """

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Notifications
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Validation.Blocking

  @tools %{
    task: "evaluate_task",
    requirements: "get_next_requirement"
  }

  @order [:task, :requirements]

  @doc """
  The menu, rendered for appending to a refusal.

  `""` when no class is live — the caller is then looking at a stop that should
  be allowed, and a menu with nothing on it would be noise.
  """
  @spec render(map(), boolean(), atom() | nil, TaskOwner.t() | nil) :: String.t()
  def render(scope, continuous? \\ false, role \\ nil, owner \\ nil) do
    case live(scope, role, owner) do
      [] ->
        ""

      [top | rest] ->
        directive(scope, top, role, owner) <>
          tally(rest) <>
          problems_note(scope, role) <>
          offers(scope, owner) <>
          tap_out_offer(continuous?)
    end
  end

  @doc """
  The way out of the autonomous loop, when the agent is in one.

  An offer, not a class: leaving the loop is not work. Shown only inside the
  loop (`continuous?` true), and never on an empty queue: with no work,
  `render/4` answers `""` and the agent simply stops, since a granted tap-out
  must be undone by hand before later work can reach it.

  `tap_out` waits on a human's approval; the unattended escape is
  `StopDecision`'s stuck detection.
  """
  @spec tap_out_offer(boolean()) :: String.t()
  def tap_out_offer(false), do: ""

  def tap_out_offer(true) do
    "\n\nThe autonomous loop is running. If continuing is not worth the tokens, " <>
      "`tap_out` asks to leave it — it returns immediately and clears the loop " <>
      "once a human approves."
  end

  @doc """
  Live classes, highest priority first, as `{class, count}`.

  Public because the decision to refuse a stop is made from whether this is
  empty; one computation keeps the message and the decision agreeing.
  """
  @spec live(map(), atom() | nil, TaskOwner.t() | nil) :: [{atom(), pos_integer()}]
  # `role` narrows the counts to that role's work; `nil` counts the project's.
  def live(scope, role \\ nil, owner \\ nil)

  # No project yet (a stop before `init_project`): every count queries by
  # `project_id`, and Ecto raises comparing a column with `nil`.
  def live(%{active_project_id: nil}, _role, _owner), do: []

  def live(scope, role, owner) do
    @order
    |> Enum.map(&{&1, count(scope, &1, role, owner)})
    |> Enum.filter(fn {_class, n} -> n > 0 end)
  end

  @doc """
  Whether problems are this role's to fix, which decides whether the menu
  mentions them; `nil` (no agent role) is unscoped.
  """
  @spec holds_problems?(atom() | nil) :: boolean()
  defdelegate holds_problems?(role), to: RoleProfile

  # The tasks the caller started and has not closed. Above requirements: a
  # second task while holding the first fills the queue with half-finished work.
  defp count(_scope, :task, _role, owner), do: length(active_tasks(owner))

  # The same answer the agent would be offered (`Work.actionable/3` with the
  # owner), so the count and the list it counts never disagree.
  defp count(scope, :requirements, role, owner),
    do: length(Work.actionable(scope, role, owner))

  # `[]` for a caller not given an owner: the class counts 0.
  defp active_tasks(nil), do: []
  defp active_tasks(owner), do: Enum.filter(TaskOwner.tasks(owner), &(&1.status == :active))

  # The newest active task, which is the one being worked: `TaskOwner.active_task/1`
  # answers the first, and an agent can hold several. Unstamped sorts oldest.
  defp newest_active_task(owner) do
    owner
    |> active_tasks()
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> List.first()
  end

  # The action goes on the `Next:` line, one instruction. The open task names
  # itself and its id, which `evaluate_task` takes.
  defp directive(scope, {:task, count}, _role, owner) do
    task = newest_active_task(owner)

    "\n\nNext: you have #{open_tasks(count)}, most recently#{task_subject(scope, task)}." <>
      obstacle(scope, task) <>
      " Nothing closes a task for you — when the work is done, call " <>
      "`evaluate_task` with task_id \"#{task.id}\". Otherwise block it with " <>
      "`ask_user_question` or `tap_out` using that task_id, or cancel the attempt " <>
      "with `cancel_task`. Disposition this active task before starting another." <>
      evaluation_feedback_note(task) <>
      backlog_note(count)
  end

  # Tools are named, never "call"ed: some are reachable only through a script.
  # `list_requirements` only to a role that carries it.
  defp directive(scope, {:requirements, count} = class_count, role, _owner) do
    case CodeMySpec.Analysis.FleetHolds.active(scope) do
      nil ->
        listing =
          if role == nil or RoleProfile.carries?(role, "list_requirements"),
            do: "`list_requirements` or ",
            else: ""

        plain(class_count) <>
          " Use #{listing}`get_next_requirement` to inspect available work, " <>
          "then choose a task with `start_task`. No requirement has been selected for you."

      hold ->
        # 783f3709: work is live, but claiming it is refused while a hold
        # stands -- said here so the agent does not spend a call finding
        # that out from `start_task` itself.
        "\n\nNext: #{label(:requirements, count)} waits — " <>
          CodeMySpec.Analysis.FleetHolds.refusal(hold)
    end
  end

  defp directive(_scope, class_count, _role, _owner), do: plain(class_count)

  defp evaluation_feedback_note(%{evaluation_feedback: nil}), do: ""

  defp evaluation_feedback_note(task) do
    repeated =
      if task.evaluation_feedback_count >= 5,
        do:
          " The same feedback has repeated #{task.evaluation_feedback_count} times; reconsider your approach.",
        else: ""

    "\n\nEvaluation feedback for task #{task.id}: #{task.evaluation_feedback}" <>
      repeated <>
      " If this is a harness defect, report it with `create_issue` using scope `framework`."
  end

  defp plain({class, count}), do: "\n\nNext: #{label(class, count)} — `#{@tools[class]}`."

  # Why the task's requirement is still open, from the checker that refused it;
  # silent when it says nothing.
  defp obstacle(scope, task) do
    case Requirements.open_reason(scope, task.requirement_name, entity_ids(task)) do
      "" -> ""
      reason -> " It is open because: #{reason}"
    end
  end

  defp entity_ids(task) do
    [task.story_id, task.component_id, task.project_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp open_tasks(1), do: "an open task"
  defp open_tasks(n), do: "#{n} open tasks"

  # Open tasks accumulate silently (only `evaluate_task` closes one), so a pile
  # is said out loud.
  defp backlog_note(1), do: ""

  defp backlog_note(_n) do
    " The others are still open too; #{list_tasks()} shows them, and each one needs " <>
      "its own `evaluate_task`."
  end

  # `list_tasks` is reachable only through a script, so it is named that way:
  # named bare, agents called it directly, got "no tool", and stood down.
  defp list_tasks, do: "`run_script` with `list_tasks({})`"

  # What the task is about, when the row says; a story by its number, which is
  # what every tool takes.
  defp task_subject(scope, %{requirement_name: name, story_id: story_id})
       when is_binary(name) and is_integer(story_id) do
    case CodeMySpec.Stories.get_story(scope, story_id) do
      %{number: number} -> " — `#{name}` on story #{number}"
      nil -> " — `#{name}`"
    end
  end

  defp task_subject(_scope, %{requirement_name: name}) when is_binary(name), do: " — `#{name}`"
  defp task_subject(_scope, _task), do: ""

  defp tally([]), do: ""

  defp tally(rest) do
    "\n\nAlso live: " <>
      Enum.map_join(rest, ", ", fn {c, n} -> label(c, n) end) <> "." <> task_tally_note(rest)
  end

  # A tallied task still names a way to its id, which `evaluate_task` needs.
  defp task_tally_note(rest) do
    if List.keymember?(rest, :task, 0) do
      " #{list_tasks()} shows them, and each one needs its own `evaluate_task`."
    else
      ""
    end
  end

  # Counts without tool names: the tally says what is waiting, not what to call.
  defp label(:task, n), do: open_tasks(n)
  defp label(:requirements, 1), do: "1 requirement"
  defp label(:requirements, n), do: "#{n} requirements"

  # Information, never a directive: problems gate at promotion. Counted through
  # `Blocking.enforceable/2`, what promotion blocks on, and only for a role that
  # can fix them.
  defp problems_note(scope, role) do
    if holds_problems?(role) do
      scope
      |> ProblemRepository.list_project_problems(severity: :error)
      |> then(&Blocking.enforceable(scope, &1))
      |> length()
      |> problems_line()
    else
      ""
    end
  end

  defp problems_line(0), do: ""

  defp problems_line(n) do
    "\n\nFor information: #{n} #{if n == 1, do: "problem is", else: "problems are"} " <>
      "recorded in this working copy (`list_problems`). They gate at promotion, " <>
      "not here."
  end

  # The offers, every time, none conditional. A pending question is an offer,
  # never a class: as a class one stale row could hold the top of the menu.
  defp offers(scope, owner) do
    answer_offer(open_questions(scope, owner)) <>
      blocked_task_note(owner) <>
      "\n\nNobody is reading this conversation. If you need a decision from the " <>
      "user, `ask_user_question` is what reaches them — name the alternatives and " <>
      "they answer with a tap; use a single free-text question when the answer is genuinely " <>
      "prose. A question written into your reply reaches no one, and stopping on " <>
      "it just brings you back here. Ask, then carry on with anything the answer " <>
      "does not block." <>
      "\n\nBefore concluding anything you are unsure of, `semantic_search` covers " <>
      "this project's own research and decisions as well as framework reference — " <>
      "a lot of what looks like a missing answer is already written down."
  end

  defp blocked_task_note(nil), do: ""

  defp blocked_task_note(owner) do
    owner
    |> TaskOwner.tasks()
    |> Enum.filter(&(&1.status == :blocked))
    |> Enum.map_join("", fn task ->
      "\n\nBlocked task #{task.id}: #{task.blocker_type} #{task.blocker_id}. " <>
        blocked_task_next(task)
    end)
  end

  # Never resumed beside an active task.
  defp blocked_task_next(%{blocker_resolved_at: nil}),
    do: "This does not block unrelated work; resume explicitly when its blocker is resolved."

  defp blocked_task_next(_released),
    do: "Its blocker is resolved; resume it with `start_task` once you hold no active task."

  # The open-question count, with the tools that show and collect replies. An
  # offer that rides a refusal and never causes one. Every role carries both
  # tools, so the sentence is true for the narrowest reader.
  defp answer_offer(0) do
    "\n\nIf a question you asked has been answered, `list_user_questions` shows " <>
      "it and `check_answer` collects the reply."
  end

  defp answer_offer(1) do
    "\n\n1 question is open and waiting on the user. `list_user_questions` shows " <>
      "it and `check_answer` collects the reply once it lands."
  end

  defp answer_offer(n) do
    "\n\n#{n} questions are open and waiting on the user. `list_user_questions` " <>
      "shows them and `check_answer` collects each reply once it lands."
  end

  # An agent's own questions; otherwise resolved from the working copy (the
  # scope carries a copy, never a session id). Never fails the stop.
  defp open_questions(_scope, %CodeMySpec.Agents.Agent{id: id}) do
    id
    |> Notifications.list_question_requests_for_agent()
    |> Enum.count(&(&1.status == "pending"))
  end

  defp open_questions(scope, _owner) do
    with id when is_binary(id) <- working_copy_id(scope),
         external_id when is_binary(external_id) <- Sessions.external_id_for_harness(id) do
      external_id
      |> Notifications.list_question_requests_for_session()
      |> Enum.count(&(&1.status == "pending"))
    else
      _ -> 0
    end
  end

  defp working_copy_id(%{active_working_copy_id: id}) when is_binary(id), do: id
  defp working_copy_id(_scope), do: 0
end
