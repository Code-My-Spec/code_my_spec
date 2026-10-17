defmodule CodeMySpecWeb.HarnessLookupControllerTest do
  @moduledoc """
  71d28513: `POST /api/harnesses` is onboarding's public entry point -- the
  first call a brand-new machine's harness ever makes, authenticated with
  nothing but its project's deploy key. A client-supplied `device_id` that
  names no row (a typo, a stale `device.json` restored onto a new machine, a
  reaped device) must answer with a 4xx this endpoint's own documented
  shapes, not a raw `Ecto.ConstraintError` 500 with a debug page.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects

  setup %{conn: conn} do
    scope = full_scope_fixture()

    # The plug resolves a deploy key to the account *owner* (see
    # DeployKeyOrOAuth), and the default fixture's user is a plain member --
    # same gap SpriteTokenControllerTest's own setup documents.
    import Ecto.Query

    CodeMySpec.Repo.update_all(
      from(m in CodeMySpec.Accounts.Member,
        where: m.user_id == ^scope.user.id and m.account_id == ^scope.active_account_id
      ),
      set: [role: :owner]
    )

    deploy_key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{deploy_key: deploy_key})

    %{
      conn:
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{deploy_key}"),
      project: project,
      scope: scope
    }
  end

  test "an unknown device_id is a 422 naming the problem, not a 500", %{
    conn: conn,
    project: project
  } do
    conn =
      post(conn, ~p"/api/harnesses", %{
        "project_id" => project.id,
        "root" => "/tmp/cms-qa-agents/unknown-device",
        "label" => "a harness with a device nobody announced",
        "device_id" => Ecto.UUID.generate()
      })

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "Could not issue"
  end

  test "a known device_id issues a working copy", %{conn: conn, project: project, scope: scope} do
    device = CodeMySpec.DevicesFixtures.device_fixture(%{scope | active_project: project})

    conn =
      post(conn, ~p"/api/harnesses", %{
        "project_id" => project.id,
        "root" => "/tmp/cms-qa-agents/known-device",
        "label" => "a harness with a real device",
        "device_id" => device.id
      })

    assert %{"working_copy_id" => id, "harness_id" => id} = json_response(conn, 200)
    assert is_binary(id)
  end
end
