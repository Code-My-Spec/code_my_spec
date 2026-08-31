defmodule CodeMySpec.WorkingCopies.PreviewUrlTest do
  @moduledoc """
  Where a project's preview answers is recorded on the checkout that serves it.

  Story 968. The preview runs where the project runs — the designated main
  checkout, the same thing the timeline header and epic dispatch key on — so the
  address belongs to that copy and to no other.

  The rule that needs a test rather than a comment is the refusal. Every
  worktree can run the app, so onboarding one with a preview URL is an easy
  mistake and a quiet one: the person believes they have set the project's
  preview, the panel goes on saying nothing is running, and neither end says
  why. Ignoring it silently is the failure; refusing names it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.WorkingCopies

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Preview #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Preview project"})
    scope = %{scope | active_project_id: project.id, active_project: project}

    %{scope: scope}
  end

  defp main_copy(scope) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/preview_main")
    copy
  end

  test "the main checkout records where its preview answers", %{scope: scope} do
    copy = main_copy(scope)

    assert copy.main, "the first rooted checkout of a project should be its main one"

    assert {:ok, saved} =
             WorkingCopies.record_preview_url(copy, "https://preview.example.test")

    assert saved.preview_url == "https://preview.example.test"

    assert WorkingCopies.preview_url(scope) == "https://preview.example.test",
           "the project cannot find the address its own main checkout just recorded"
  end

  test "a checkout that is not the main one is refused", %{scope: scope} do
    _main = main_copy(scope)

    {:ok, other} =
      WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

    {:ok, other} = WorkingCopies.report_root(other, "/tmp/preview_worktree")

    refute other.main, "the second checkout should not have taken the designation"

    assert {:error, :not_the_main_copy} =
             WorkingCopies.record_preview_url(other, "https://wrong.example.test"),
           "a worktree was allowed to claim it is where the preview runs. Every worktree " <>
             "can run the app, so accepting this gives the panel two answers to a " <>
             "question that has one."
  end

  test "a project whose main checkout has no address reports nothing", %{scope: scope} do
    _main = main_copy(scope)

    refute WorkingCopies.preview_url(scope),
           "a project with no preview recorded reported one. Nothing is the ordinary " <>
             "state and the panel says so — an empty string or a stale value there is a " <>
             "frame pointed at nowhere."
  end

  test "a project with no main checkout at all reports nothing", %{scope: scope} do
    {:ok, orphan} =
      WorkingCopies.issue(scope, nil, label: "unrooted", device: device_fixture(scope))

    refute orphan.main,
           "a checkout that never said where it is was designated, which is the quiet " <>
             "failure `report_root/2` exists to avoid"

    refute WorkingCopies.preview_url(scope)
  end

  test "the address survives being read back rather than living in the harness", %{scope: scope} do
    copy = main_copy(scope)
    {:ok, _} = WorkingCopies.record_preview_url(copy, "https://durable.example.test")

    # Read through a fresh lookup rather than the struct just returned. The rule
    # is that the address is written down: a value only present in whatever the
    # writer happened to hold would pass on that struct and be gone on restart.
    assert WorkingCopies.preview_url(scope) == "https://durable.example.test"
  end
end
