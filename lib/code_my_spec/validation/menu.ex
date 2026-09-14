defmodule CodeMySpec.Validation.Menu do
  @moduledoc """
  What to do next, said in the refusal.

  The stop hook answers one question — may you stop? — and until now it only
  ever said no by naming findings. It never said what to do instead, so an agent
  whose own area was clear had to guess, and guessing is what this exists to
  stop: a framework queue emptied, nothing said so, and the agent kept sweeping
  surfaces looking for work. The last of those returned ~900 "orphan components"
  that are not defects at all.

  ## Classes and offers are different things

  A **class** is countable state — rows the hook can see and rank. An **offer**
  is a line printed regardless, because the condition it serves cannot be
  detected.

  The distinction is load-bearing and was got wrong twice. Needing input is an
  intention, and no query answers "does this agent want to ask something" — a
  first draft made it a class anyway, with a scenario beginning "Given the agent
  has work it cannot proceed on without a decision from the user", a Given
  nothing can evaluate.

  The second time was subtler. A pending question *is* detectable, so
  `check_answer` was made a class and ranked first, on the reasoning that a
  waiting reply is cheap and may change what the right work is. Both true, and
  it was still wrong: it let one row outrank every real class of work, and
  `e39b4eba` — a question answered anywhere but `QuestionLive` never closes —
  meant a stale row could hold the top of the menu permanently. Detectable is
  necessary for a class, not sufficient. It also has to be work in this working
  copy that the hook can rank against other work.

  ## The order

      1. problems       list_problems          do not start new work on a broken
                                               tree
      2. task           evaluate_task          finish what you already started
      3. requirements   get_next_requirement

  Issues were the second class here and are not any more. The graph already
  carries them — `issues_triaged` is product's and `issues_resolved` is
  coding's, both counted by `IssuesChecker` against
  `fix_issues_min_severity` — so a class beside them was the same work counted
  twice, by the cruder of the two accountings: no role, no threshold, and
  ranked *above* the graph's own answer.

  It showed the day role scoping landed. Three agents on one copy were each sent
  to `list_issues` with the same 14, on a project where all 14 were incoming and
  therefore product's alone, because the class could not tell triage from
  resolution and did not know what a role was.

  Problems keep their class for the opposite reason: no requirement models them
  at all, so this is the only place they surface as work.

  One directive, not the whole menu: a full list on every stop buries the
  important item among the easy ones and invites the agent to take whichever is
  cheapest. But the rest are tallied rather than dropped, because a class that
  is never mentioned starves invisibly — which is the failure a strict single
  directive has.

  ## Three offers, none conditional

  `check_answer`, `ask_user_question`, `semantic_search`. Every refusal carries all
  three, because what they serve — a reply the agent has not read, a decision it
  needs, a fact already written down somewhere — is invisible from here. They
  cost three lines and cannot starve anything.

  The last of those is the one most often skipped in practice, and the most
  expensive: a great deal of what an agent needs is already written down, and
  one that does not think to search reasons from nothing and produces confident
  nonsense. That is harder to catch than a red test.
  """

  alias CodeMySpec.Notifications
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.TaskOwner

  @tools %{
    problems: "list_problems",
    task: "evaluate_task",
    requirements: "get_next_requirement"
  }

  @order [:problems, :task, :requirements]

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
          tally(rest) <> offers(scope) <> tap_out_offer(continuous?)
    end
  end

  @doc """
  The way out of the autonomous loop, when the agent is in one.

  Conditional, unlike the other three, and the condition does not break the
  class/offer split: `session.continuous` is a flag, as detectable as a row.
  What makes this an offer rather than a class is that leaving the loop is not
  work — it cannot be ranked against problems and must not compete for the
  directive.

  Shown only inside the loop, because inviting an agent to tap out of a loop it
  is not running is worse than saying nothing: it reads as an instruction and
  the tool would refuse it.

  Public so the continuous-mode refusal in `Hooks.Stop` can carry it too. That
  refusal builds its own reason — the next assignment — rather than a menu, and
  it is the one an agent sees most while burning tokens in a loop, so it is the
  last place that should omit the exit.

  Worth knowing what this does and does not buy: `tap_out` publishes a
  permission request and waits on a human, so it is not an escape the agent can
  take alone. The one that fires unattended is R8's stuck detection, at
  `@stuck_threshold` identical blocks.
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
  empty, and computing it twice from different queries is how the message and
  the decision come to disagree.
  """
  @spec live(map(), atom() | nil, TaskOwner.t() | nil) :: [{atom(), pos_integer()}]
  # `role` narrows the requirements count to that role's work — story 538's R10,
  # so a coding agent is not held open by product's queue. `nil` counts the
  # project's, which is what every caller outside the loop wants.
  def live(scope, role \\ nil, owner \\ nil)

  # A working copy that has not been bound to a project yet. Every count below
  # queries by `project_id`, and Ecto refuses to compare a column with `nil`
  # rather than silently matching nothing — so this raised on a stop fired
  # before `init_project`, which is the one stop that must stay quiet.
  def live(%{active_project_id: nil}, _role, _owner), do: []

  def live(scope, role, owner) do
    @order
    |> Enum.map(&{&1, count(scope, &1, role, owner)})
    |> Enum.filter(fn {_class, n} -> n > 0 end)
  end

  # The task the caller already started and has not closed.
  #
  # A class rather than an offer, and it passes both tests this module holds: it
  # is countable state — an embedded row with `status: :active` — and it is work
  # in this working copy, so it can be ranked against problems.
  #
  # It exists because of what an agent did on 2026-09-06. Working
  # `three_amigos_complete` on story 994, it started the task, got as far as a
  # question it needed answered — whether open borders are bilateral and
  # revocable — wrote that question into its reply, and stopped. Nothing was
  # reading the transcript, and the menu it got on the way out said "call
  # `get_next_requirement`" — advice for an agent holding no work, handed to one
  # holding an open task. Both halves of that stop were wrong and the menu
  # named neither.
  #
  # Ranked below problems, because a broken tree still comes first: a task
  # evaluated against a tree that will not compile fails on the tree rather than
  # on the work. Ranked above requirements, because taking a second task while
  # still holding the first is how a queue fills with half-finished work.
  defp count(_scope, :task, _role, owner), do: length(active_tasks(owner))

  # Held only by the roles that can do something about them.
  #
  # This ignored role entirely while requirements were scoped by it (R10), so a
  # QA agent was held open by the project's compile and spex errors — 47 of
  # them on the war-epic copy — and answered, correctly and repeatedly:
  # "`list_problems` is not available to this QA role, so I cannot inspect the
  # 47 Spex findings." It could not read them, could not fix them, and could not
  # stop. John: "it shouldn't get blocked by problems."
  #
  # `:coding` fixes code and `:main` does everything, so a broken tree is their
  # business and the class still outranks their requirements — work built on a
  # tree that will not compile fails on the tree. `:qa` tests a story and
  # `:product` writes specs; neither has a move that clears a compile error, and
  # a directive nobody can act on is the shape this whole module exists to stop.
  #
  # Unscoped for `nil`, which is every caller outside the loop — the project's
  # own count, which is what a person asking about the tree wants.
  @problem_roles [:coding, :main]

  defp count(_scope, :problems, role, _owner)
       when is_atom(role) and not is_nil(role) and role not in @problem_roles,
       do: 0

  # Counted through `Validation.enforceable/2`, which is what the gate actually
  # blocks on — not everything recorded.
  #
  # That function's own doc says why it is public: "two copies of what counts as
  # enforceable drift, and the drift is silent." This was the third copy, and it
  # drifted the furthest, because the population it counted was the whole
  # project.
  #
  # What the gap looked like. A spex failure on a story that has not reached
  # `bdd_specs_passing` is the red bar that drives the implementation — expected,
  # by design, and `split_by_story_enforcement/3` already holds it back from the
  # gate for exactly that reason. The menu counted it anyway. Broken Oaths on
  # 2026-09-08 opened every coding stop with "133 problems in this working copy"
  # over a backlog that was 127 unwritten features across ten stories, ranked
  # above the agent's own requirements, none of it its work and none of it
  # blocking anything. The agent read the list, correctly found nothing of its
  # own in it, and stopped. Every time.
  #
  # John: "those specs should not be contributing to the problems yet because
  # the development's not done."
  #
  # Three extra reads on a path that already recomputes a graph, and it is the
  # difference between a directive an agent can act on and a wall.
  defp count(scope, :problems, _role, _owner) do
    scope
    |> ProblemRepository.list_project_problems(severity: :error)
    |> then(&CodeMySpec.Validation.enforceable(scope, &1))
    |> length()
  end

  # Through the same fingerprint-checked path every other reader uses.
  #
  # This read `requirements` rows directly, and the comment here explained why:
  # `next_actionable/1` "recomputes on a cache miss and globs the working copy —
  # fatal here, because the stop decision runs inside the channel process for a
  # harness-served project, so the process that would serve the glob is the one
  # waiting on it."
  #
  # That hazard is gone and the note outlived it. `DelegateFiles` used to hash a
  # few working-copy files off disk; `RequirementGraph` records that classify
  # claims those files now, so `files_digest` covers them by content hash "and
  # the side channel is gone". `Preloader.load/1` is `Repo.all/1`. A recompute
  # is ~170ms and touches nothing but the database.
  #
  # What the workaround cost: rows are only written when something computes the
  # graph, and nothing computes it on a file change or a finished task. So the
  # menu counted work that had already been done, sent the agent to
  # `get_next_requirement` for it, and the agent was told there was none — every
  # six seconds, until enough recomputes caught the rows up. A count and the
  # list it counts, disagreeing, which is exactly what one source prevents.
  defp count(scope, :requirements, role, _owner),
    do: Requirements.actionable_count(scope, role)

  # `[]` for every caller not given an owner — the class then counts 0 and the
  # menu reads exactly as it did before this existed.
  defp active_tasks(nil), do: []
  defp active_tasks(owner), do: Enum.filter(TaskOwner.tasks(owner), &(&1.status == :active))

  # The one the agent is actually working on, which is the newest.
  #
  # `TaskOwner.active_task/1` answers the *first* active task, and that is the
  # wrong end. Nothing closes a task except `evaluate_task`, and an agent that
  # starts work without finishing it leaves the old row active — the product
  # agent on the war-epic copy was holding seven when this was written, the
  # oldest `story_issues_resolved` on story 904 and the newest
  # `three_amigos_complete` on story 994, which was the one it was mid-thought
  # on. Naming the oldest would send it back to work it had already moved past.
  #
  # `started_at` is stamped at microsecond resolution, so ordering by it is
  # exact. A task with no stamp sorts oldest, which is right: it was never
  # started.
  defp newest_active_task(owner) do
    owner
    |> active_tasks()
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> List.first()
  end

  # The tool call goes on the `Next:` line rather than below it. A directive
  # whose action sits on the following line reads as two facts, and the agent
  # has to join them; on one line it is a single instruction.
  # The open task names itself, because "1 open task" is not actionable and the
  # id is not something the agent can look up from here. `evaluate_task` takes
  # the id, so the directive carries the id.
  defp directive(scope, {:task, count}, _role, owner) do
    task = newest_active_task(owner)

    "\n\nNext: you have #{open_tasks(count)}, most recently#{task_subject(task)}." <>
      obstacle(scope, task) <>
      " Nothing closes a task for you — when the work is done, call " <>
      "`evaluate_task` with task_id \"#{task.id}\". If it is not done, finish it " <>
      "before taking anything else." <> backlog_note(count)
  end

  # Names the tool; does not say "call" it.
  #
  # It used to, and that was a false instruction to half the agents reading it.
  # `list_problems` is reachable from a script and deliberately not carried
  # directly — story 1038's rule, and a good one: every carried schema is read
  # on every turn, which is the cost code mode exists to remove. Carrying it to
  # make the sentence true was the wrong direction and criterion 3015 caught it.
  #
  # An agent that holds the tool calls it; one that does not looks it up with
  # `tool_docs` and calls it in a script. Naming it is true for both.
  # The count, then what the first of them is.
  #
  # A second sentence rather than a rewrite of the first, so "1 requirement —
  # `get_next_requirement`" still reads exactly as it did. The whole menu is
  # still one directive: this names the item the agent is about to be handed,
  # not the list.
  #
  # Criterion 3185 is what asks for it, and from the position that matters: the
  # only work on that project is a story interview, and an agent told "1
  # requirement" cannot tell whether it is the one thing it can do or the one
  # thing it cannot. It spends a turn on `get_next_requirement` finding out.
  # `directive/3`'s `:task` clause has named its subject since it was written,
  # for the same reason.
  defp directive(scope, {:requirements, _count} = class_count, role, _owner) do
    plain(class_count) <> next_requirement_note(scope, role)
  end

  defp directive(_scope, class_count, _role, _owner), do: plain(class_count)

  defp plain({class, count}), do: "\n\nNext: #{label(class, count)} — `#{@tools[class]}`."

  # Reads the role the count was taken with, not the owner's own. They are the
  # same for every caller today, and a caller that passed one and owned the
  # other would otherwise get a sentence naming work its count never included.
  #
  # Silent when there is nothing to name — a class that is not live never
  # reaches here, but an actionable set that emptied underneath this render
  # does.
  defp next_requirement_note(scope, role) do
    case Requirements.actionable_for_role(scope, role) do
      [%{description: description} | _] when is_binary(description) ->
        " The first is: #{description}"

      _ ->
        ""
    end
  end

  # Why the requirement is still open, from the checker that refused it.
  #
  # Was two copies of this sentence — one here, one in each caller's own nudge —
  # and only the transcript-only copies ever carried it: the text an agent was
  # actually sent named the open task and never what was holding it. Watched
  # live on 2026-09-10: a coding agent nudged every 90 seconds about
  # `code_on_running_copy` while the gate refused on "uncommitted changes —
  # commit them", and the message never said so.
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

  # A pile of open tasks is a fact about this agent worth saying out loud. They
  # accumulate silently — only `evaluate_task` closes one — so an agent that
  # starts work it does not finish looks, from every other surface, exactly like
  # an agent that is busy.
  defp backlog_note(1), do: ""

  defp backlog_note(_n) do
    " The others are still open too; `list_tasks` shows them, and each one needs " <>
      "its own `evaluate_task`."
  end

  # What the task is about, when the row says. Both fields are nullable and a
  # task with neither is still worth naming as open.
  defp task_subject(%{requirement_name: name, story_id: story_id})
       when is_binary(name) and is_integer(story_id),
       do: " — `#{name}` on story #{story_id}"

  defp task_subject(%{requirement_name: name}) when is_binary(name), do: " — `#{name}`"
  defp task_subject(_task), do: ""

  defp tally([]), do: ""

  defp tally(rest) do
    "\n\nAlso live: " <>
      Enum.map_join(rest, ", ", fn {c, n} -> label(c, n) end) <> "." <> task_tally_note(rest)
  end

  # A task tallied rather than leading still has to name a way to its id — the
  # directive carries it inline, but the tally names only a count, and
  # `evaluate_task` needs the id. Without this an agent whose menu leads with
  # problems learns it is holding a task and never how to act on it.
  defp task_tally_note(rest) do
    if List.keymember?(rest, :task, 0) do
      " `list_tasks` shows them, and each one needs its own `evaluate_task`."
    else
      ""
    end
  end

  # Counts without their tool names, deliberately. The tally says what is
  # waiting; naming its call too would make four instructions out of one, which
  # is the full menu this is meant to avoid.
  defp label(:task, n), do: open_tasks(n)
  defp label(:problems, 1), do: "1 problem in this working copy"
  defp label(:problems, n), do: "#{n} problems in this working copy"
  defp label(:requirements, 1), do: "1 requirement"
  defp label(:requirements, n), do: "#{n} requirements"

  # Three offers, every time, none of them conditional.
  #
  # `ask_user` was withdrawn while a question was outstanding, on the reasoning
  # that asking twice fills a queue with duplicates. John reversed it: "it's
  # totally fine for the model to ask another question of the user." He is
  # right, and the withdrawal was solving the wrong problem — the duplicate
  # queue came from `ask_user` blocking inline and being retried after a
  # transport timeout, which splitting it into ask-then-check fixed at the
  # source. A second, *different* question while one is pending is an agent with
  # two needs, not that failure.
  #
  # `check_answer` was the top of the tier, ranked above problems on the
  # reasoning that a waiting reply is cheap and may change what the right work
  # is. That is true and it is still not a class: it made a pending question
  # outrank every real class of work, and `e39b4eba` — a question answered
  # anywhere but `QuestionLive` never closes — meant one stale row could hold
  # the top of the menu permanently. As an offer it costs a line and cannot
  # starve anything. John: "we should offer answers unconditionally and they
  # will have to ultimately be scoped by conversation."
  #
  # That scoping is the real fix for `e39b4eba` and is not built here.
  #
  # What is left in the tiers is only what the hook can both detect and rank:
  # rows describing work in this working copy.
  defp offers(scope) do
    answer_offer(open_questions(scope)) <>
      "\n\nNobody is reading this conversation. If you need a decision from the " <>
      "user, `ask_user_question` is what reaches them — name the alternatives and " <>
      "they answer with a tap; `send_message` is for when the answer is genuinely " <>
      "prose. A question written into your reply reaches no one, and stopping on " <>
      "it just brings you back here. Ask, then carry on with anything the answer " <>
      "does not block." <>
      "\n\nBefore concluding anything you are unsure of, `semantic_search` covers " <>
      "this project's own research and decisions as well as framework reference — " <>
      "a lot of what looks like a missing answer is already written down."
  end

  # The count is a fact about now; the offer without it is boilerplate that
  # reads identically whether nothing is waiting or three things are. Story 896.
  #
  # It stays an *offer* rather than becoming a class, which is the distinction
  # this module exists to hold: a pending question is detectable but is not work
  # in this working copy, so it cannot be ranked against problems. It rides a
  # refusal caused by something else and never causes one — an unanswered
  # question that could refuse a stop would pin the agent in the loop with no
  # work available to escape.
  defp answer_offer(0) do
    "\n\nIf a question you asked has been answered, `check_answer` has the reply."
  end

  defp answer_offer(1) do
    "\n\n1 question is open and waiting on the user — `list_user_questions` shows it, " <>
      "`check_answer` collects a reply once it lands."
  end

  defp answer_offer(n) do
    "\n\n#{n} questions are open and waiting on the user — `list_user_questions` shows them, " <>
      "`check_answer` collects a reply once one lands."
  end

  # Resolved from the working copy, the same asymmetry `ask_user` works around:
  # the scope carries a harness and never a session id.
  #
  # Never raises the stop. A question count that could fail the hook would make
  # asking a question a liability, and the whole point is that asking is cheap.
  defp open_questions(scope) do
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
