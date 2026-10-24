defmodule CodeMySpec.Projects.OnboardingTest do
  use CodeMySpecTest.DataCase, async: false
  alias CodeMySpec.Projects.Onboarding
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    %{scope: %{scope | active_project_id: project.id, active_project: project}}
  end

  test "decisions and sources survive reload and partial edits", %{scope: scope} do
    assert {:ok, project} =
             Onboarding.save(scope, %{
               "onboarding" => %{
                 "starting_point" => "existing",
                 "description" => "An app for gardeners"
               },
               "sources" => [
                 %{"kind" => "github", "repository_url" => "https://github.com/example/garden"}
               ]
             })

    assert project.onboarding.starting_point == :existing
    assert [source] = project.sources
    assert source.assessment == :pending
    assert {:ok, updated} = Onboarding.save(scope, %{onboarding: %{destination: :local}})
    assert updated.onboarding.description == "An app for gardeners"
    assert updated.sources == project.sources
    assert {:ok, reloaded} = Onboarding.fetch(scope)
    assert reloaded == updated
    assert {:ok, cleared} = Onboarding.save(scope, %{sources: []})
    assert cleared.sources == []
  end

  test "local paths are tied to an accessible device", %{scope: scope} do
    {:ok, device} = CodeMySpec.Devices.announce(scope, nil, %{kind: :local, hostname: "laptop"})

    assert {:ok, project} =
             Onboarding.save(scope, %{
               sources: [%{kind: :local, path: "/home/me/app", device_id: device.id}]
             })

    assert hd(project.sources).device_id == device.id

    assert {:error, changeset} =
             Onboarding.save(scope, %{
               sources: [%{kind: :local, path: "/home/me/app", device_id: Ecto.UUID.generate()}]
             })

    assert Enum.any?(errors_on(changeset).sources, &Map.has_key?(&1, :device_id))
  end

  test "bad selections are rejected without changing persisted state", %{scope: scope} do
    assert {:error, changeset} =
             Onboarding.save(scope, %{
               onboarding: %{starting_point: "unknown"},
               sources: [%{kind: :github, repository_url: "https://evil.example/repo"}]
             })

    assert %{onboarding: %{starting_point: [_]}, sources: [%{repository_url: [_]}]} =
             errors_on(changeset)

    assert {:ok, project} = Onboarding.fetch(scope)
    assert project.onboarding == nil
    assert project.sources == []

    assert {:error, changeset} =
             Onboarding.save(scope, %{sources: [%{kind: :local, path: "relative"}]})

    assert %{sources: [%{path: [_], device_id: [_]}]} = errors_on(changeset)
  end

  test "another account's project cannot be accessed or changed", %{scope: scope} do
    other_user = user_fixture()
    account = account_with_owner_fixture(other_user)
    other_scope = user_scope_fixture(other_user, account)
    project = project_fixture(other_scope)
    assert {:error, :not_found} = Onboarding.fetch(%{scope | active_project_id: project.id})

    assert {:error, :not_found} =
             Onboarding.save(
               %{scope | active_project_id: project.id, active_account_id: account.id},
               %{onboarding: %{starting_point: :new}}
             )
  end

  test "saving selection cannot claim an inspection was completed", %{scope: scope} do
    assert {:ok, project} =
             Onboarding.save(scope, %{
               sources: [
                 %{
                   kind: :github,
                   repository_url: "https://github.com/example/repo",
                   assessment: :phoenix
                 }
               ]
             })

    assert hd(project.sources).assessment == :pending
  end
end
