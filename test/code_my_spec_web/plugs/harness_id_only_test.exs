defmodule CodeMySpecWeb.Plugs.HarnessIdOnlyTest do
  @moduledoc """
  `X-Harness-Id` is sufficient on its own, and wins when a project header
  disagrees with it.

  A harness *is* a working copy and belongs to exactly one project, so it
  settles both questions at once. `X-Project-ID` is the coarser key: two
  worktrees of one project send the same value, so on its own the far end cannot
  tell them apart and answers about both — `await_analysis` reported 1141 credo
  problems to a copy that has 563, the rest belonging to a checkout it could not
  see and could not fix.

  The plugin used to send only the project header on the cloud mount, which is
  exactly that failure, and sending the pair is the shape that lets them
  disagree. Both mounts send the harness id alone now.
  """
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Harnesses
  alias CodeMySpecWeb.Plugs.ProjectScopeOverride

  defp run(conn, scope, headers) do
    Enum.reduce(headers, Plug.Conn.assign(conn, :current_scope, scope), fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
    |> ProjectScopeOverride.call([])
  end

  test "a harness id alone resolves the project", %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, harness} = Harnesses.issue(scope, nil, label: "a checkout")

    result = run(conn, scope, [{"x-harness-id", harness.id}])

    assert result.assigns.current_scope.active_project_id == scope.active_project_id
    assert result.assigns.current_scope.active_harness_id == harness.id
    refute result.halted
  end

  test "the harness wins when a project header names something else", %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, harness} = Harnesses.issue(scope, nil, label: "a checkout")

    # A second project in the *same account*, so the override would genuinely
    # succeed if the project header won. A project from another account is
    # denied for access reasons and the assign never changes — which makes the
    # test pass whether or not the harness was consulted. It did, until this
    # was checked by ignoring the harness header and watching it stay green.
    {:ok, sibling} =
      CodeMySpec.Projects.create_project(scope, %{
        name: "sibling-#{System.unique_integer([:positive])}",
        module_name: "Sibling"
      })

    result =
      run(conn, scope, [
        {"x-harness-id", harness.id},
        {"x-project-id", sibling.id}
      ])

    refute result.halted

    assert result.assigns.current_scope.active_project_id == scope.active_project_id, """
    A project header for a reachable sibling project overrode the harness.

    The two answer the same question and the harness is the more specific of
    them, so it is the one to keep. Letting the coarser one win is how a request
    ends up answering about a checkout the caller cannot see.
    """

    assert result.assigns.current_scope.active_harness_id == harness.id
  end

  test "an unknown harness is refused rather than falling back to the project", %{conn: conn} do
    scope = full_scope_fixture()

    result =
      run(conn, scope, [
        {"x-harness-id", Ecto.UUID.generate()},
        {"x-project-id", scope.active_project_id}
      ])

    assert result.halted, """
    An id this server does not know fell through to the project header.

    That turns a client pointed somewhere wrong into a plausible answer about a
    project it happens to also name — which is worse than a refusal, because
    nothing about the reply says it is not the checkout that asked.
    """

    assert result.status == 404
  end

  test "a project id alone still works, for callers that only have one", %{conn: conn} do
    scope = full_scope_fixture()

    result = run(conn, scope, [{"x-project-id", scope.active_project_id}])

    refute result.halted
    assert result.assigns.current_scope.active_project_id == scope.active_project_id
  end

  test "an unexpanded variable is not an id", %{conn: conn} do
    scope = full_scope_fixture()

    result = run(conn, scope, [{"x-harness-id", "${CMS_HARNESS_ID}"}])

    refute result.halted,
           "an unset variable arrives literally; treating it as an unknown harness " <>
             "would refuse every request from a plugin that was never onboarded, " <>
             "instead of passing through as unscoped"
  end
end
