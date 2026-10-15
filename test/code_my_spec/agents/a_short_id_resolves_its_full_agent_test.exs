defmodule CodeMySpec.Agents.AShortIdResolvesItsFullAgentTest do
  @moduledoc """
  98d45f5c: a team assignment names a teammate by the same short id this
  project uses everywhere else (issues, commits) -- the first several
  characters of its full UUID -- never the full UUID itself. `fetch_agent/2`
  only ever accepted a full UUID (`Ecto.UUID.cast/1`), so `message_agent`
  refused every short id with "No agent or conversation with that id exists
  here", even when it named exactly one agent in the project.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/short-id-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    %{scope: scope, agent: agent}
  end

  test "an 8-character prefix of the full id resolves to its agent", %{scope: scope, agent: agent} do
    short_id = String.slice(agent.id, 0, 8)

    assert {:ok, resolved} = AgentsRepository.fetch_agent(scope, short_id)
    assert resolved.id == agent.id
  end

  test "a prefix matching no agent in the project is not found", %{scope: scope} do
    assert {:error, :not_found} = AgentsRepository.fetch_agent(scope, "ffffffff")
  end

  test "a prefix matching more than one agent is refused as ambiguous rather than guessed", %{
    scope: scope
  } do
    attrs = %{
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      provider: "anthropic",
      engine: :alloy,
      role: "qa",
      working_copy: "/tmp/short-id-#{System.unique_integer([:positive])}",
      working_copy_id: scope.active_working_copy_id
    }

    {:ok, _a} =
      %CodeMySpec.Agents.Agent{id: "deadbeef-0000-4000-8000-000000000001"}
      |> CodeMySpec.Agents.Agent.changeset(attrs)
      |> CodeMySpec.Repo.insert()

    {:ok, _b} =
      %CodeMySpec.Agents.Agent{id: "deadbeef-0000-4000-8000-000000000002"}
      |> CodeMySpec.Agents.Agent.changeset(attrs)
      |> CodeMySpec.Repo.insert()

    assert {:error, :not_found} = AgentsRepository.fetch_agent(scope, "deadbeef")
  end

  test "a sub-agent label still falls through unmatched, not coerced into a prefix search", %{
    scope: scope
  } do
    assert {:error, :not_found} = AgentsRepository.fetch_agent(scope, "aqa-1013-example")
  end
end
