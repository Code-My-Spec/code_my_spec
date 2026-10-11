defmodule CodeMySpec.Agents.Main.ATapOutIsMainsFirstTest do
  @moduledoc """
  Criteria 2073 and 2074 (story 1060): a coding, QA or product agent's tap-out
  is the main agent's from the moment it is raised; main's own goes to the user.

  It used to be the user's until it had waited one recovery interval (the
  retired 1980/1991), so a fresh tap-out reached main only by ageing. On
  2026-10-11 a coder's four tap-outs sat with John while main, idle, never saw
  them.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.OpenQuestion

  defp tap_out(attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        tool_name: "tap_out",
        tool_input: %{"reason" => "blocked"},
        escalation_reason: nil,
        escalated_as: nil,
        inserted_at: DateTime.utc_now(),
        agent_id: Ecto.UUID.generate()
      },
      attrs
    )
  end

  defp agent(role), do: %{role: role, working_copy_id: nil, status: :running}

  test "a fresh tap-out from coding, QA or product is the main agent's" do
    for role <- [:coding, :qa, :product] do
      assert %{holder: "main_agent"} = OpenQuestion.from_permission(tap_out(), agent(role), nil)
    end
  end

  test "the main agent's own tap-out is the user's" do
    assert %{holder: "user"} = OpenQuestion.from_permission(tap_out(), agent(:main), nil, true)
  end

  test "a tap-out main escalated is the user's" do
    escalated = tap_out(%{escalation_reason: "product decision"})
    assert %{holder: "user"} = OpenQuestion.from_permission(escalated, agent(:coding), nil)
  end
end
