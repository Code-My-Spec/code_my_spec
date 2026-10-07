defmodule CodeMySpec.Agents.TheMainBriefKeepsTheFleetMovingTest do
  @moduledoc """
  The main brief says the fleet is main's to keep moving, not only its questions.

  Measured 2026-10-07 on a continuous Codex main: it answered every question
  pushed to it, and acknowledged without acting two held-back offers, a declined
  resume, a QA agent that had paused itself for machine load with nothing to
  wake it, and a committed fix nobody was carrying to promotion. Its brief was
  entirely about answering questions; `process/main_agent.md` covers stalls, and
  nothing loads it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleBrief

  @brief RoleBrief.for(:main)

  test "names what is stopped, not only what is asked" do
    assert @brief =~ ~r/held back|declined/i
    assert @brief =~ ~r/stalled|stopped/i
    assert @brief =~ ~r/promot/i
  end

  test "asks for a state-changing call rather than an acknowledgement" do
    assert @brief =~ ~r/acknowledg/i
  end
end
