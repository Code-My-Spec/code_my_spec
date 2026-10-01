defmodule CodeMySpec.Agents.OnlyMainStartsOnTheMainCopyTest do
  @moduledoc """
  The project's main checkout is the main agent's home; coding and QA never
  start there.

  The guard used to allow exactly one agent of any role on the main copy, so a
  coding agent could take the seat whenever main was not running. metric_flow
  carried one from 09-24 until John retired it ("no coding agent belongs on the
  main copy"). Which roles may start there is each role's
  `RoleProfile.home_copy`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  setup do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, main} = WorkingCopies.fetch(scope.active_working_copy_id)
    device = device_fixture(scope)

    main =
      main
      |> Ecto.Changeset.change(root: "/workspace/main", main: true, device_id: device.id)
      |> Repo.update!()

    feature =
      %WorkingCopy{}
      |> WorkingCopy.changeset(%{
        project_id: scope.active_project_id,
        device_id: device.id,
        root: "/workspace/feature",
        label: "a feature checkout"
      })
      |> Repo.insert!()

    %{scope: %{scope | cwd: main.root}, main: main, feature: feature}
  end

  defp start(scope, role, copy) do
    Agents.start_agent(scope, %{
      provider: "anthropic",
      role: role,
      engine: :alloy,
      working_copy_id: copy.id
    })
  end

  for role <- ~w(coding qa) do
    test "#{role} is refused on the empty main copy", %{scope: scope, main: main} do
      assert {:error, {:not_at_home, unquote(String.to_atom(role)), root}} =
               start(scope, unquote(role), main),
             "a #{unquote(role)} agent started on the main checkout. Only the roles " <>
               "whose home is the main copy may start there, and the seat being free " <>
               "does not make it theirs."

      assert root == main.root
    end

    test "#{role} still starts on a feature copy", %{scope: scope, feature: feature} do
      assert {:ok, agent} = start(scope, unquote(role), feature)
      assert agent.working_copy_id == feature.id
    end
  end

  test "main starts on the main copy", %{scope: scope, main: main} do
    assert {:ok, agent} = start(scope, "main", main)
    assert agent.working_copy_id == main.id
  end

  test "the one-agent rule still holds for main", %{scope: scope, main: main} do
    assert {:ok, _} = start(scope, "main", main)
    assert {:error, {:main_copy_occupied, _root}} = start(scope, "main", main)
  end

  test "the refusal says which roles live there, in words", %{scope: scope, main: main} do
    {:error, reason} = start(scope, "coding", main)

    said = reason |> AgentsMapper.error("anthropic") |> then(& &1.content) |> inspect()

    assert said =~ "coding"
    assert said =~ "main"
    refute said =~ "{:not_at_home"
  end
end
