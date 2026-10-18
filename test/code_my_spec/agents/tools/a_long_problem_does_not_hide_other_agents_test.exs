defmodule CodeMySpec.Agents.Tools.ALongProblemDoesNotHideOtherAgentsTest do
  @moduledoc """
  One agent's problem text cannot crowd the others out of the listing.

  metric_flow, 2026-09-27: a failure message carrying a rendered LiveView page
  filled the 24,000-character answer cap on its own, so `list_agent_work`
  ended after the main agent's entry and the coding and product agents it
  manages were never shown.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Tools.AgentWorkResponses, as: AgentWorkMapper

  defp agent(id, role, problems) do
    %AgentWork{agent_id: id, role: role, agent_status: :running, problems: problems}
  end

  test "each finding is one short line, and every agent still appears" do
    page = "** (ExUnit.AssertionError) assert html =~ x\n" <> String.duplicate("<div>", 20_000)

    work = [
      agent("main-id", :main, [
        %{source: "exunit", file_path: "test/a_test.exs", line: 3, message: page}
      ]),
      agent("coding-id", :coding, []),
      agent("product-id", :product, [])
    ]

    text = AgentWorkMapper.text(work)

    assert text =~ "coding-id"
    assert text =~ "product-id"
    refute text =~ "<div>"
    assert byte_size(text) < 4_000
  end
end
