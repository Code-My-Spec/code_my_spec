defmodule CodeMySpec.Agents.Tools.CheckIn do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent

  @impl true
  def name, do: "check_in"

  @impl true
  def description do
    """
    Look in on your agents now, without waiting for the next scheduled wake-up.

    The same digest the cadence delivers — what every agent is working on, the
    health of the machinery under them, and every question waiting on somebody.
    Assembled from all three, so a failure in any one of them is reported as a
    failure rather than as a shorter list: an empty digest and an unbuildable one
    read identically, and only one of them is good news.

    The cadence is a floor, never a schedule — the longest anything can go unseen.
    Nothing here waits for it: a question raised now is pushed now, and this is
    how you look when you have a reason to rather than when the timer says so.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> deliver(MainAgent.check_in(scope))
      {:error, reason} -> refusal(reason)
    end
  end

  # `check_in/1` answers the rendered digest now, so this hands it straight
  # back rather than describing it.
  #
  # It used to return one static sentence whatever the fleet was doing, and
  # `CheckInReport.render/1` — fully written, documented, and citing this very
  # criterion — was called by nothing at all. So a caller got "recovery
  # inspected the fleet" and had to go and run `list_agent_work` to learn any
  # of what it inspected, which is the opposite of the module's own promise
  # that "the wake-up is an answer instead of a turn spent getting to one".
  # Found by QA on story 1012 (`375be60f`).
  #
  # The digest is still not *pushed* anywhere: this is a reply to whoever
  # asked, and no unconditional message goes to any agent.
  defp deliver({:ok, report}), do: {:ok, report}

  # A digest that could not be assembled has already raised a fault, and is
  # reported as the failure it is rather than as an empty, healthy fleet —
  # criterion 3333's whole point is that those are opposite answers and the
  # empty one is the reassuring half.
  defp deliver({:error, reason}) do
    {:error, "The check-in could not be assembled: #{reason}. A fault has been recorded."}
  end

  defp refusal(reason) do
    {:error, "Could not check in: #{inspect(reason)}"}
  end
end
