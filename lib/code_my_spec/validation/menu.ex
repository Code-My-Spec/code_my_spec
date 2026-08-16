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

  The distinction is load-bearing and was got wrong once. Needing input is an
  intention, and no query answers "does this agent want to ask something". A
  first draft made it a class anyway, with a scenario beginning "Given the agent
  has work it cannot proceed on without a decision from the user" — a Given
  nothing can evaluate. So `ask_user` is an offer, and only `check_answer` is a
  class, because asking wrote a row and wanting to ask did not.

  ## The order

      1. questions      check_answer         a reply already waiting is the
                                             cheapest thing on the list, and the
                                             one most likely to change what the
                                             right work is
      2. problems       list_problems        do not start new work on a broken
                                             tree
      3. issues         list_issues
      4. requirements   get_next_requirement

  One directive, not the whole menu: a full list on every stop buries the
  important item among the easy ones and invites the agent to take whichever is
  cheapest. But the rest are tallied rather than dropped, because a class that
  is never mentioned starves invisibly — which is the failure a strict single
  directive has.

  ## The offer is withdrawn in exactly one case

  While a question is outstanding, `ask_user` is not offered. Asking again
  before reading the reply to the last one is how a queue fills with the same
  question — the failure that split the blocking `ask_user` into ask-then-check
  in the first place, when a transport timeout made each retry create another
  row while telling the agent the tool was broken.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions

  @tools %{
    questions: "check_answer",
    problems: "list_problems",
    issues: "list_issues",
    requirements: "get_next_requirement"
  }

  @order [:questions, :problems, :issues, :requirements]

  @doc """
  The menu, rendered for appending to a refusal.

  `""` when no class is live — the caller is then looking at a stop that should
  be allowed, and a menu with nothing on it would be noise.
  """
  @spec render(map()) :: String.t()
  def render(scope) do
    case live(scope) do
      [] -> ""
      [top | rest] -> directive(top) <> tally(rest) <> offer(questions_live?(scope))
    end
  end

  @doc """
  Live classes, highest priority first, as `{class, count}`.

  Public because the decision to refuse a stop is made from whether this is
  empty, and computing it twice from different queries is how the message and
  the decision come to disagree.
  """
  @spec live(map()) :: [{atom(), pos_integer()}]
  # A working copy that has not been bound to a project yet. Every count below
  # queries by `project_id`, and Ecto refuses to compare a column with `nil`
  # rather than silently matching nothing — so this raised on a stop fired
  # before `init_project`, which is the one stop that must stay quiet.
  def live(%{active_project_id: nil}), do: []

  def live(scope) do
    @order
    |> Enum.map(&{&1, count(scope, &1)})
    |> Enum.filter(fn {_class, n} -> n > 0 end)
  end

  # Read off `live/1` rather than re-queried, so the offer and the tally can
  # never disagree about whether a question is outstanding.
  defp questions_live?(scope), do: List.keymember?(live(scope), :questions, 0)

  # Both a pending question and an answered-but-unread one send the agent to
  # `check_answer` — from the hook's side they are the same instruction, and the
  # tool itself reports which it found. What they share is that neither is
  # resolved, so neither should produce another question.
  defp count(scope, :questions) do
    scope
    |> session_external_id()
    |> Notifications.list_question_requests_for_session()
    |> Enum.count(&(&1.status in ["pending", "answered"]))
  end

  defp count(scope, :problems) do
    scope
    |> ProblemRepository.list_project_problems(severity: :error)
    |> length()
  end

  defp count(scope, :issues) do
    scope
    |> Issues.list_issues()
    |> Enum.count(&(&1.status in [:incoming, :accepted, "incoming", "accepted"]))
  end

  # The actionable count, when the graph is already cached, and nothing when it
  # is not.
  #
  # Two wrong versions preceded this. The first called `next_actionable/1`, which
  # recomputes on a cache miss — the recompute runs the checkers, the checkers
  # glob the working copy, and the stop decision runs inside the channel process
  # for a harness-served project, so the process that would serve the glob is the
  # one blocked waiting for it. `harness_project_channel_test` timed out at
  # 4949ms with "it accepted the request and did not answer".
  #
  # The second counted rows off `requirements` directly, which read 5 against the
  # graph's 58 — because `project_id` is set only on project-level nodes.
  # Component requirements carry `component_id` and story requirements carry
  # `story_id`, both leaving `project_id` null, so the filter selected 13 of
  # about 4,900 rows. Joining through components and stories would have fixed the
  # scoping and still given the wrong number: every unsatisfied node, including
  # ones no agent can start. "1,700 requirements" is true and useless.
  #
  # So: the actionable set, which is what `get_next_requirement` would hand back,
  # read only when it costs a cache hit. A miss omits the class rather than
  # paying for a recompute — a menu is worth a missing line, never a deadlock.
  defp count(scope, :requirements) do
    case RequirementGraph.cached_actionable_count(scope) do
      {:ok, n} -> n
      :miss -> 0
    end
  end

  defp session_external_id(%{active_harness_id: id}), do: Sessions.external_id_for_harness(id)
  defp session_external_id(_scope), do: nil

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
  defp label(:questions, 1), do: "1 question outstanding"
  defp label(:questions, n), do: "#{n} questions outstanding"
  defp label(:problems, 1), do: "1 problem in this working copy"
  defp label(:problems, n), do: "#{n} problems in this working copy"
  defp label(:issues, 1), do: "1 issue"
  defp label(:issues, n), do: "#{n} issues"
  defp label(:requirements, 1), do: "1 requirement"
  defp label(:requirements, n), do: "#{n} requirements"

  defp offer(true), do: ""

  defp offer(false) do
    "\n\nIf you need something from the user to go further, call `ask_user` — " <>
      "nothing here can tell that you do."
  end
end
