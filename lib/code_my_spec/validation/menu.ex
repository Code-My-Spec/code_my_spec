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
      2. issues         list_issues
      3. requirements   get_next_requirement

  One directive, not the whole menu: a full list on every stop buries the
  important item among the easy ones and invites the agent to take whichever is
  cheapest. But the rest are tallied rather than dropped, because a class that
  is never mentioned starves invisibly — which is the failure a strict single
  directive has.

  ## Three offers, none conditional

  `check_answer`, `ask_user`, `semantic_search`. Every refusal carries all
  three, because what they serve — a reply the agent has not read, a decision it
  needs, a fact already written down somewhere — is invisible from here. They
  cost three lines and cannot starve anything.

  The last of those is the one most often skipped in practice, and the most
  expensive: a great deal of what an agent needs is already written down, and
  one that does not think to search reasons from nothing and produces confident
  nonsense. That is harder to catch than a red test.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Requirements.NodeRepository
  alias CodeMySpec.Sessions

  @tools %{
    problems: "list_problems",
    issues: "list_issues",
    requirements: "get_next_requirement"
  }

  @order [:problems, :issues, :requirements]

  @doc """
  The menu, rendered for appending to a refusal.

  `""` when no class is live — the caller is then looking at a stop that should
  be allowed, and a menu with nothing on it would be noise.
  """
  @spec render(map(), boolean()) :: String.t()
  def render(scope, continuous? \\ false, role \\ nil) do
    case live(scope, role) do
      [] -> ""
      [top | rest] -> directive(top) <> tally(rest) <> offers(scope) <> tap_out_offer(continuous?)
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
  @spec live(map(), atom() | nil) :: [{atom(), pos_integer()}]
  # `role` narrows the requirements count to that role's work — story 538's R10,
  # so a coding agent is not held open by product's queue. `nil` counts the
  # project's, which is what every caller outside the loop wants.
  def live(scope, role \\ nil)

  # A working copy that has not been bound to a project yet. Every count below
  # queries by `project_id`, and Ecto refuses to compare a column with `nil`
  # rather than silently matching nothing — so this raised on a stop fired
  # before `init_project`, which is the one stop that must stay quiet.
  def live(%{active_project_id: nil}, _role), do: []

  def live(scope, role) do
    @order
    |> Enum.map(&{&1, count(scope, &1, role)})
    |> Enum.filter(fn {_class, n} -> n > 0 end)
  end

  defp count(scope, :problems, _role) do
    scope
    |> ProblemRepository.list_project_problems(severity: :error)
    |> length()
  end

  defp count(scope, :issues, _role) do
    scope
    |> Issues.list_issues()
    |> Enum.count(&(&1.status in [:incoming, :accepted, "incoming", "accepted"]))
  end

  # Straight off the read model, which is where this always belonged.
  #
  # Two versions preceded it and both tried to compute an answer the rows
  # already hold. The first called `next_actionable/1`, which recomputes on a
  # cache miss and globs the working copy — fatal here, because the stop
  # decision runs inside the channel process for a harness-served project, so
  # the process that would serve the glob is the one waiting on it. The second
  # read the cached graph instead, which never deadlocks and also never answers:
  # the fingerprint hashes the file digest and the stop hook syncs files before
  # deciding, so the entry is stale by the time the menu renders.
  #
  # `requirements` and `requirement_edges` are a read model. Actionable is a
  # graph query over it — unsatisfied, minus anything with an unsatisfied
  # prerequisite — and needs no recompute, no cache and no filesystem. John's
  # point, and it is the answer: nothing about a stop should require rethinking
  # the graph.
  defp count(scope, :requirements, role), do: NodeRepository.actionable_count(scope, role)

  # The tool call goes on the `Next:` line rather than below it. A directive
  # whose action sits on the following line reads as two facts, and the agent
  # has to join them; on one line it is a single instruction.
  defp directive({class, count}) do
    "\n\nNext: #{label(class, count)} — call `#{@tools[class]}`."
  end

  defp tally([]), do: ""

  defp tally(rest) do
    "\n\nAlso live: " <> Enum.map_join(rest, ", ", fn {c, n} -> label(c, n) end) <> "."
  end

  # Counts without their tool names, deliberately. The tally says what is
  # waiting; naming its call too would make four instructions out of one, which
  # is the full menu this is meant to avoid.
  defp label(:problems, 1), do: "1 problem in this working copy"
  defp label(:problems, n), do: "#{n} problems in this working copy"
  defp label(:issues, 1), do: "1 issue"
  defp label(:issues, n), do: "#{n} issues"
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
      "\n\nIf you need something from the user to go further, call `ask_user` — " <>
      "nothing here can tell that you do." <>
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
