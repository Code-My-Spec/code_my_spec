defmodule CodeMySpec.Analysis.ASubagentIdIsNotAnAgentTest do
  @moduledoc """
  The `subagent_stop` hook records a Claude Code subagent id — short hex, not a
  UUID — as `requested_by["agent_id"]`. `AgentReport` queried it as an agent's
  `:binary_id`, raised, and failed the reconcile of a run that had completed.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.AgentReport

  test "a non-UUID requester is treated as no in-app requester, not a crash" do
    scope = full_scope_fixture()

    assert :ok = AgentReport.deliver(scope, "compiler", [], "af6cbaec65372da7a")
  end

  test "a UUID requester still goes through" do
    scope = full_scope_fixture()

    assert :ok = AgentReport.deliver(scope, "compiler", [], Ecto.UUID.generate())
  end
end
