defmodule CodeMySpec.Agents.Main.Digest do
  @moduledoc """
  What the main agent is handed when the cadence wakes it.

  Story 1059, criterion 3332. A bare "time to check in" costs a turn before
  anything is known — `list_agent_work`, then `check_machinery`, then thinking
  — seventy-two times a day on the machine that is also running the agents.
  And a wake-up that says nothing is one an agent can reasonably glance at and
  dismiss, which turns the check-in into ceremony.

  ## Failure is a value, not an empty list

  Criterion 3333, and the reason this is a struct rather than a list. A digest
  that could not be built and arrives empty says exactly what a healthy fleet
  says, for as long as whatever broke stays broken, and nothing can tell the
  difference — because everywhere else in this system "no rows" means nothing is
  wrong.

  So `failed` is a field and every reader has to pass it. There is no shape this
  struct can take where "I could not look" is indistinguishable from "I looked
  and all is well".
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Agents.Main.TokenBurn

  # `off` is agents somebody turned off. Shown so the main agent leaves them
  # off; never part of `quiet?/1`, because an off agent is settled (39af5611).
  @type t :: %__MODULE__{
          work: [AgentWork.t()],
          off: [Agent.t()],
          machinery: Machinery.t() | nil,
          questions: [OpenQuestion.t()],
          requirements:
            %{total: non_neg_integer(), satisfied: non_neg_integer()}
            | {:unavailable, String.t()}
            | nil,
          completions: [struct()],
          tokens: [TokenBurn.t()],
          main_copy_id: Ecto.UUID.t() | nil,
          previous_requirements: %{total: non_neg_integer(), satisfied: non_neg_integer()} | nil,
          failed: String.t() | nil
        }

  defstruct work: [],
            off: [],
            machinery: nil,
            questions: [],
            requirements: nil,
            completions: [],
            # Each agent's token use over the last hour (`TokenBurn`).
            tokens: [],
            # Whose problems are main's own: the project's main working copy.
            main_copy_id: nil,
            # What the previous check-in counted, for the change since (2477).
            previous_requirements: nil,
            failed: nil

  @doc "A digest that could not be assembled, and what stopped it."
  @spec failed(String.t()) :: t()
  def failed(reason), do: %Digest{failed: reason}

  @doc """
  Whether this check-in found anything worth a person's attention.

  Criterion 3320: seventy-two quiet check-ins a day reaching somebody is a pager
  that fires on a timer, and the reasonable response is to turn it off — which
  removes the one mechanism that catches a silent agent.

  A digest that could not be built is *not* quiet. That is the whole of 3333:
  the absence of findings is only good news when the looking worked.
  """
  @spec quiet?(t()) :: boolean()
  def quiet?(%Digest{failed: reason}) when is_binary(reason), do: false

  def quiet?(%Digest{} = digest) do
    digest.questions == [] and digest.completions == [] and machinery_ok?(digest.machinery) and
      Enum.all?(digest.work, &settled?/1) and TokenBurn.over_threshold(digest.tokens) == [] and
      Enum.all?(copy_problems(digest), &(not &1.raised?))
  end

  @doc """
  Each working copy with blocking problems, once — not once per agent on it.

  A problem belongs to a copy, so a coder and a QA sharing one failing test are
  one entry (criterion 2473). `raised?` is whether it is main's to look at
  (criterion 2480): the copy is the main working copy, or one of its problems is
  also on another copy, which no single team's change explains. Anything else is
  a team's work in progress — counted, not raised.
  """
  @spec copy_problems(t()) :: [
          %{
            working_copy_id: Ecto.UUID.t(),
            root: String.t() | nil,
            problems: [map()],
            raised?: boolean()
          }
        ]
  def copy_problems(%Digest{failed: reason}) when is_binary(reason), do: []

  def copy_problems(%Digest{work: work, main_copy_id: main}) do
    copies =
      work
      |> Enum.filter(&(&1.problems != [] and is_binary(&1.working_copy_id)))
      |> Enum.uniq_by(& &1.working_copy_id)

    shared =
      copies
      |> Enum.flat_map(fn entry -> entry.problems |> Enum.map(&problem_key/1) |> Enum.uniq() end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> MapSet.new(fn {key, _count} -> key end)

    Enum.map(copies, fn entry ->
      %{
        working_copy_id: entry.working_copy_id,
        root: entry.working_copy_root,
        problems: entry.problems,
        raised?:
          entry.working_copy_id == main or
            Enum.any?(entry.problems, &MapSet.member?(shared, problem_key(&1)))
      }
    end)
  end

  defp problem_key(problem), do: {problem.source, problem.file_path, problem.message}

  @doc """
  Who main is told about as stalled (step 4b): running, holding no task, no
  turn open, while the graph holds work for their role — `AgentWork.unclaimed_work/1`'s
  STALLED. Not one out of the loop or damped (those are said, not stalls), and
  never main itself.
  """
  @spec stalled(t()) :: [AgentWork.t()]
  def stalled(%Digest{failed: reason}) when is_binary(reason), do: []

  def stalled(%Digest{work: work}), do: Enum.filter(work, &teammate_stalled?/1)

  defp teammate_stalled?(entry) do
    stalled?(entry) and entry.role != :main and entry.continuous? != false and
      is_nil(entry.damped)
  end

  defp machinery_ok?(nil), do: true
  defp machinery_ok?(%Machinery{tool_fault: :none}), do: true
  defp machinery_ok?(%Machinery{}), do: false

  # Working or idle as expected, which is criterion 3320's own phrasing. An
  # agent holding a task it has not spoken about for hours is neither.
  defp settled?(%AgentWork{} = entry) do
    entry.blocked_reasons == [] and
      not AgentWork.toolless?(entry) and not AgentWork.provider_blocked?(entry) and
      not AgentWork.timing_out?(entry) and not stalled?(entry)
  end

  # An agent with nothing in hand and a queue that is not empty is the one state
  # this module existed to catch and did not.
  #
  # `idle?` is "no task AND the graph's queue for this role is empty" — genuinely
  # nothing to do, and settled. The inverse pairing is the interesting one: no
  # task and a queue that DOES hold work means the agent should be working and
  # is not. `CheckInReport` already renders exactly that ("no task claimed, and
  # the graph does hold work for its role"), so the report could say it while
  # `quiet?/1` suppressed the check-in that would have carried it.
  #
  # Why that matters more than one stuck agent. `Cadence`'s own docs call it "a
  # floor, not a schedule ... the longest anything can go unseen", and the design
  # it belongs to is: every wake is edge-triggered, and the cadence is the safety
  # net under all of them. `Work.consider_*` fires on a graph change, a finished
  # task, continuous being switched on, a harness joining — and a missed edge is
  # therefore a permanent stall, because nothing polls. The net could not catch
  # any of it while an idle-but-eligible agent counted as settled.
  #
  # Measured 2026-09-23 on Broken Oaths. Four distinct missed edges were found
  # and fixed individually in one night — a restarted agent, a resumed agent, an
  # answered question, a denied tap-out — and after all four, QA sat running,
  # continuous, zero declines, no turn open, with `get_next_requirement`
  # answering "ready — QaStory story 950" and no edge coming. Each individual fix
  # is still right; this is the thing that would have made any of them survivable
  # before it was found.
  #
  # Deliberately not `tapped_out?`: that agent asked to stop and being left alone
  # is the answer to its own request. Nor an agent mid-turn — a turn in flight is
  # working, whatever its queue says.
  #
  # A blocked task is no work in hand: it holds only itself (story 1080).
  #
  # Nor one with a turn on its way (`Offers.in_flight?/1`): that is the seconds
  # between an offer and its claim. Main was told "STALLED" for team 2's coder
  # at 03:21:36 with the promote it claimed at 03:21:46 offered at 03:21:35, and
  # a flag that fires on every handover is one main learns to discount
  # (2026-10-13). A turn handed over before and never started is a stall even
  # with another on its way — a harness that swallows turns is re-offered every
  # recovery check — and says what was offered (`AgentWork.unclaimed_work/1`).
  defp stalled?(
         %AgentWork{
           agent_status: :running,
           task_status: status,
           idle?: false,
           turn_started_at: nil,
           tapped_out?: false,
           provider_refusal: nil
         } = entry
       )
       when status in [nil, :blocked],
       do: not entry.turn_in_flight? or not is_nil(entry.unstarted_turn)

  defp stalled?(%AgentWork{}), do: false
end
