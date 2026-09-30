defmodule CodeMySpec.MainAgent.Digest do
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
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.OpenQuestion

  # `off` is agents somebody turned off. Shown so the main agent leaves them
  # off; never part of `quiet?/1`, because an off agent is settled (39af5611).
  @type t :: %__MODULE__{
          work: [AgentWork.t()],
          off: [Agent.t()],
          machinery: Machinery.t() | nil,
          questions: [OpenQuestion.t()],
          failed: String.t() | nil
        }

  defstruct work: [], off: [], machinery: nil, questions: [], failed: nil

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
    digest.questions == [] and machinery_ok?(digest.machinery) and
      Enum.all?(digest.work, &settled?/1)
  end

  defp machinery_ok?(nil), do: true
  defp machinery_ok?(%Machinery{tool_fault: :none}), do: true
  defp machinery_ok?(%Machinery{}), do: false

  # Working or idle as expected, which is criterion 3320's own phrasing. An
  # agent holding a task it has not spoken about for hours is neither.
  defp settled?(%AgentWork{} = entry) do
    entry.blocked_reasons == [] and entry.problems == [] and
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
  defp stalled?(%AgentWork{
         agent_status: :running,
         task_status: nil,
         idle?: false,
         turn_started_at: nil,
         tapped_out?: false,
         provider_refusal: nil
       }),
       do: true

  defp stalled?(%AgentWork{}), do: false
end
