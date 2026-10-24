defmodule CodeMySpecWeb.DevBoxOnboardingTest do
  @moduledoc """
  Issue 2dae034c (story 1131): a dev box onboards a checkout from its access
  token alone, with no deploy key, for projects in its own account only.
  """
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Oauth
  alias CodeMySpec.Repo

  setup %{conn: conn} do
    scope = full_scope_fixture()
    owner = user_fixture()
    _ = member_fixture(owner, scope.active_account, :owner)

    {:ok, box} =
      %Device{}
      |> Device.dev_box_changeset(%{
        label: "cloud-1",
        provider: :local,
        kind: :local,
        account_id: scope.active_account_id,
        token_hash: "hash-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, access} = Oauth.issue_box_token(box, owner, 60)

    %{
      conn:
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{access.token}"),
      scope: scope,
      box: box
    }
  end

  test "a box onboards a checkout of its own account's project", ctx do
    conn =
      post(ctx.conn, "/api/harnesses", %{
        "project_id" => ctx.scope.active_project_id,
        "root" => "/workspace/app",
        "device_id" => ctx.box.id
      })

    assert %{"working_copy_id" => id, "project_id" => project_id} = json_response(conn, 200)
    assert is_binary(id)
    assert project_id == ctx.scope.active_project_id
  end

  test "a box is refused another account's project", ctx do
    other = full_scope_fixture()

    conn =
      post(ctx.conn, "/api/harnesses", %{
        "project_id" => other.active_project_id,
        "root" => "/workspace/app",
        "device_id" => ctx.box.id
      })

    assert json_response(conn, 403)["error"] =~ "outside this dev box's account"
  end

  test "a box cannot look up another account's working copy", ctx do
    other = full_scope_fixture()
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(other.active_working_copy_id)

    conn = get(ctx.conn, "/api/harnesses/#{copy.id}")

    assert json_response(conn, 403)
  end
end
