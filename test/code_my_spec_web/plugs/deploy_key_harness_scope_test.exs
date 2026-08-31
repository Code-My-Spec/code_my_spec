defmodule CodeMySpecWeb.Plugs.DeployKeyHarnessScopeTest do
  @moduledoc """
  An MCP caller's scope names the working copy it is calling from.

  Without it, every read runs unscoped — `scope_to_harness/2` treats a nil
  harness as "no filter" rather than "no results", which is right for the
  project-wide views it was written for and wrong for an agent asking about
  its own checkout. `await_analysis` reported 1138 credo problems to an agent
  whose own tree had 552; the remainder belonged to a different worktree it
  cannot see and could not fix.

  The proxy has always addressed itself as `/mcp?harness=<id>`. The scope just
  never read it.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.Plugs.DeployKeyOrOAuth

  setup do
    scope = full_scope_fixture()
    project = scope.active_project

    # The plug resolves the account *owner* — a question is an interruption and
    # it will not interrupt the wrong person — so the fixture's plain member is
    # not enough to get past the deploy-key branch. Promoted rather than added,
    # since one user has one membership per account.
    import Ecto.Query

    CodeMySpec.Repo.update_all(
      from(m in CodeMySpec.Accounts.Member,
        where: m.user_id == ^scope.user.id and m.account_id == ^scope.active_account.id
      ),
      set: [role: :owner]
    )

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{deploy_key: "dk-#{project.id}"})

    {:ok, scope: scope, project: project, token: project.deploy_key}
  end

  defp call(token, query) do
    Phoenix.ConnTest.build_conn(:get, "/mcp?" <> query)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> DeployKeyOrOAuth.call([])
  end

  defp call_with_header(token, working_copy_id) do
    Phoenix.ConnTest.build_conn(:get, "/mcp/harness")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("x-harness-id", working_copy_id)
    |> DeployKeyOrOAuth.call([])
  end

  test "adopts the harness from the x-harness-id header", %{scope: scope, token: token} do
    {:ok, harness} =
      WorkingCopies.issue(scope, nil, label: "a checkout", device: device_fixture(scope))

    conn = call_with_header(token, harness.id)

    assert conn.assigns.current_scope.active_working_copy_id == harness.id,
           "this is how it actually arrives: the proxy resolves /mcp?harness=<id> " <>
             "on its own port and forwards to /mcp/harness, so only the header " <>
             "survives. The first version of this read the query param, passed its " <>
             "test, and did nothing in production"
  end

  test "adopts the harness the caller names in the query", %{scope: scope, token: token} do
    {:ok, harness} =
      WorkingCopies.issue(scope, nil, label: "a checkout", device: device_fixture(scope))

    conn = call(token, "harness=#{harness.id}")

    assert conn.assigns.current_scope.active_working_copy_id == harness.id
  end

  test "ignores a harness belonging to another project", %{token: token} do
    other = full_scope_fixture()

    {:ok, foreign} =
      WorkingCopies.issue(other, nil,
        label: "someone else's checkout",
        device: device_fixture(other)
      )

    conn = call(token, "harness=#{foreign.id}")

    refute conn.assigns.current_scope.active_working_copy_id == foreign.id,
           "adopting another project's working copy is worse than reading widely"
  end

  test "stays unscoped when no harness is named", %{token: token} do
    conn = call(token, "")

    assert is_nil(conn.assigns.current_scope.active_working_copy_id)
  end

  test "stays unscoped on a malformed id rather than raising", %{token: token} do
    conn = call(token, "harness=not-a-uuid")

    assert is_nil(conn.assigns.current_scope.active_working_copy_id)
  end
end
