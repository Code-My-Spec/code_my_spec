defmodule CodeMySpec.Agents.ThinningACrowdedWorkingCopyTest do
  @moduledoc """
  An agent you can see from outside a project is an agent you can stop.

  `message_any_agent/3` already crossed projects for the dev routes, because an
  operator looking at the fleet is not inside any one project's scope. Stopping
  did not, so a working copy that had collected three coding agents could be
  observed and not thinned — and three coding agents on one checkout is three
  stories in flight and, measured on Broken Oaths 2026-09-08, seven concurrent
  analyzer runs against one Postgres.

  The project is read off the agent's own row. That is what keeps the
  repository's `:cross_project` guard honest rather than bypassed: the write
  still goes through `stop_agent/2` with a scope that matches the agent.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a crowded checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp coding_agent(scope, copy) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        working_copy: "/tmp/thinning-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    agent
  end

  test "an agent is stopped without being handed a scope", %{scope: scope, copy: copy} do
    agent = coding_agent(scope, copy)

    assert {:ok, stopped} = Agents.stop_any_agent(agent.id)
    assert stopped.id == agent.id
    assert stopped.status == :stopped
  end

  test "an id nobody has is refused rather than raising" do
    assert {:error, :no_such_agent} = Agents.stop_any_agent(Ecto.UUID.generate())
  end

  # The guard this route must not become a way around. Stopping resolves the
  # project from the row, so there is no caller-supplied project id that could
  # disagree with the agent's — which is the only way `update_agent/3` could be
  # reached with a mismatched scope.
  test "one agent's stop leaves its neighbours alone", %{scope: scope, copy: copy} do
    mine = coding_agent(scope, copy)
    theirs = coding_agent(scope, copy)

    assert {:ok, _} = Agents.stop_any_agent(mine.id)

    assert {:ok, untouched} = AgentsRepository.fetch_agent(scope, theirs.id)
    assert untouched.status == theirs.status
  end
end
