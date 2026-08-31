defmodule CodeMySpecWeb.HarnessProjectModuleNameTest do
  @moduledoc """
  Only the main checkout may say what the project is called.

  The correction exists because a checkout's `mix.exs` is "the one place it is
  never ambiguous". That is true of a checkout and false of a project, which has
  several — and every one of them sends this on every sync, so without a gate the
  last to sync wins.

  Found the expensive way. A QA sandbox holding a different application
  (`:qa_sandbox`) sat on the CodeMySpec project for an afternoon and renamed it
  `QaSandbox`, against 1,091 components all called `CodeMySpec.*`. It kept
  renaming it after being un-designated as main, because merely being connected
  was enough. The architecture task then read that name and instructed its agent
  to create components in a namespace that does not exist.

  The gate is the main copy rather than a new rule, because "which checkout
  defines this project" is a question the project already answers.
  """

  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{module_name: "Real"})

    %{
      scope: %{scope | active_project: project},
      project: project,
      topic: "harness_project:#{scope.active_project_id}"
    }
  end

  defp join_as(scope, topic) do
    socket(UserSocket, "module_name_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, topic, %{
      "label" => "the harness at /workspace/app",
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_fixture(scope).id}
    })
  end

  defp set_main(scope, main?) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    copy |> Ecto.Changeset.change(main: main?) |> CodeMySpec.Repo.update!()
  end

  defp module_name(project), do: CodeMySpec.Repo.reload!(project).module_name

  test "the main checkout corrects it", %{scope: scope, topic: topic, project: project} do
    set_main(scope, true)
    {:ok, _, socket} = join_as(scope, topic)

    ref = push(socket, "module_name", %{"module_name" => "Renamed"})
    assert_reply(ref, :ok)

    assert module_name(project) == "Renamed",
           "the main checkout is the project's own answer to which mix.exs counts, " <>
             "and gating on it must not break the self-healing this was built for."
  end

  test "any other checkout does not", %{scope: scope, topic: topic, project: project} do
    set_main(scope, false)
    {:ok, _, socket} = join_as(scope, topic)

    ref = push(socket, "module_name", %{"module_name" => "QaSandbox"})
    assert_reply(ref, :ok)

    assert module_name(project) == "Real",
           "a checkout that is not the main one renamed the project. This is how a " <>
             "QA sandbox holding a different application renamed CodeMySpec to " <>
             "QaSandbox and kept doing it after being un-designated — every copy " <>
             "sends this on every sync, so ungated it is last-writer-wins between " <>
             "checkouts that may not even be the same app."
  end

  test "the reply is still :ok, so a non-main harness is not told it failed", %{
    scope: scope,
    topic: topic
  } do
    set_main(scope, false)
    {:ok, _, socket} = join_as(scope, topic)

    ref = push(socket, "module_name", %{"module_name" => "QaSandbox"})

    # Refusing loudly would make every non-main harness log an error on every
    # sync for doing exactly what it is supposed to do. Ignoring is the answer,
    # and the blank-name clause beside it already works that way.
    assert_reply(ref, :ok)
  end
end
