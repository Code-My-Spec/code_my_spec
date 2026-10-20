defmodule CodeMySpec.Agents.QaWakeSeedTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import ExUnit.CaptureIO

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Projects

  @seed Path.expand("../../../priv/repo/qa_wake_seed.exs", __DIR__)

  setup do
    path = CodeMySpec.TempFile.owned_dir("qa_wake_seed")
    File.write!(Path.join(path, "mix.exs"), "# Existing disposable app fixture\n")
    user = user_fixture(%{email: "qa@codemyspec.local"})
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Math Test Project",
        module_name: "MathTestProject",
        local_path: path
      })

    scope = user_scope_fixture(user, account, project)
    %{scope: scope}
  end

  test "creates the agent set and refreshes off-duty fixtures without duplicating them", %{
    scope: scope
  } do
    capture_io(fn -> Code.eval_file(@seed) end)
    agents = AgentsRepository.list_agents(scope)
    assert Enum.frequencies_by(agents, & &1.role) == %{coding: 2, main: 1, product: 1}
    assert Enum.all?(agents, &Agents.on_duty?/1)
    assert Enum.all?(agents, & &1.continuous)

    product = Enum.find(agents, &(&1.role == :product))

    {:ok, _} =
      AgentsRepository.update_agent(scope, product, %{
        off_at: DateTime.utc_now(),
        off_by: "QA fixture",
        off_reason: "Previous pass ended",
        continuous: false,
        turn_started_at: DateTime.utc_now()
      })

    capture_io(fn -> Code.eval_file(@seed) end)
    refreshed = Repo.get!(Agent, product.id)
    assert Agents.on_duty?(refreshed)
    assert refreshed.continuous
    assert refreshed.off_by == nil
    assert refreshed.off_reason == nil
    assert refreshed.turn_started_at == nil

    assert Enum.sort(Enum.map(AgentsRepository.list_agents(scope), & &1.id)) ==
             Enum.sort(Enum.map(agents, & &1.id))
  end
end
