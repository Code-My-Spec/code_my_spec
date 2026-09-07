defmodule CodeMySpec.Workspaces.InstanceCopyReuseTest do
  @moduledoc """
  A cloud instance brought back after it went down is the same working copy.

  Booting replaces the container — `Runner.start/4` removes whatever was there
  first — so a retry is the same checkout at the same root, not a second one.

  Minting a fresh copy per boot was not a tidiness problem. Only the project's
  *first* rooted checkout is designated main, and only the main copy is given a
  preview, so a workspace that crashed and was retried came back holding a copy
  that could never have an address — while the address still on the visitor's
  screen belonged to the copy that no longer existed and answered 530. The
  preview was permanently broken for that project by one crash, and nothing
  reported it.

  Found QA'ing story 968 in a browser, on the retry path rather than the happy
  one. The first attempt at this test passed against the broken code, because
  `boot/1` short-circuits on a workspace that is still running and never reaches
  the code under test — the workspace has to actually be down.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.{WorkingCopies, Workspaces}
  alias CodeMySpecTest.FakeWorkspaceRunner

  setup do
    CodeMySpecSpex.Fixtures.install_workspace_runner(healthy?: true, serving: :serving)

    user = user_fixture()
    account = account_fixture(%{name: "Reuse #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = project_fixture(scope, %{name: "reusetest"})
    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    {:ok, scope: scope}
  end

  test "a retry after the instance goes down reuses the copy", %{scope: scope} do
    {:ok, _workspace} = Workspaces.boot(scope)

    [first] = WorkingCopies.list_harnesses(scope)

    assert first.main,
           "the first cloud copy was not designated main, so it would never be " <>
             "given a preview and the rest of this test is meaningless"

    # The instance goes away. This is the state the test exists for: with it
    # still alive, `boot/1` returns the running workspace and never reaches the
    # code under test.
    FakeWorkspaceRunner.put_alive(false)

    {:ok, _workspace} = Workspaces.boot(scope)

    copies = WorkingCopies.list_harnesses(scope)

    assert length(copies) == 1,
           "a retry minted a second working copy. Only the project's first rooted " <>
             "checkout is main and only the main copy gets a preview, so the " <>
             "visitor's rebuilt project can never have an address — while the one " <>
             "on their screen points at a container that no longer exists. Got: " <>
             inspect(Enum.map(copies, &{&1.id, &1.main, &1.root}))

    assert hd(copies).id == first.id, "the copy was replaced rather than reused"
    assert hd(copies).main, "the reused copy lost its designation, so it loses its preview"
  end

  test "the instance is told the copy it is reusing", %{scope: scope} do
    {:ok, _} = Workspaces.boot(scope)
    [first] = WorkingCopies.list_harnesses(scope)

    FakeWorkspaceRunner.put_alive(false)
    {:ok, _} = Workspaces.boot(scope)

    # What the container was handed on the second boot. Onboarding uses this to
    # ask the server for its preview, so an id that disagreed with the row would
    # be the same bug wearing a different hat.
    [{_name, _app, _port, env} | _] = FakeWorkspaceRunner.calls()

    assert env |> Map.new() |> Map.get("CMS_WORKING_COPY_ID") == first.id,
           "the rebuilt instance was told it is a different copy than the one the " <>
             "server holds for it"
  end
end
