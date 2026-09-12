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

  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.OpenQuestion

  @type t :: %__MODULE__{
          work: [AgentWork.t()],
          machinery: Machinery.t() | nil,
          questions: [OpenQuestion.t()],
          failed: String.t() | nil
        }

  defstruct work: [], machinery: nil, questions: [], failed: nil

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
    entry.blocked_reasons == [] and entry.problems == [] and not AgentWork.toolless?(entry)
  end
end
