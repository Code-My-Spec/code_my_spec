defmodule CodeMySpecWeb.SpriteTokenControllerTest do
  @moduledoc """
  A sprite has no user and no browser, so it cannot run an OAuth flow. It holds
  its project's deploy key and trades it here for a real access token.

  The alternative was accepting the deploy key across the harness tool surface,
  which `Plugs.DeployKeyOrOAuth` argues against in its own moduledoc: a key that
  can interrupt its owner should not thereby inherit everything that owner can
  do. Exchanging keeps that boundary and gets expiry and per-sprite revocation
  as well.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects

  setup %{conn: conn} do
    scope = full_scope_fixture()

    # The exchange resolves the deploy key to the account *owner* — a question,
    # and now a token, belongs to whoever the project belongs to. The default
    # fixture makes its user a plain member, so without this the plug correctly
    # refuses and the test would be exercising nothing.
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
      conn: put_req_header(conn, "accept", "application/json"),
      scope: scope,
      project: project,
      deploy_key: deploy_key
    }
  end

  test "a deploy key buys an access token for its own project", %{
    conn: conn,
    project: project,
    deploy_key: deploy_key
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{deploy_key}")
      |> post(~p"/api/sprite/token", %{})

    assert %{
             "access_token" => token,
             "token_type" => "Bearer",
             "expires_in" => expires_in,
             "project_id" => project_id
           } = json_response(conn, 200)

    assert is_binary(token) and byte_size(token) > 20
    assert project_id == project.id

    assert expires_in > 0,
           "a token that never expires is a deploy key with extra steps — expiry is half the point"
  end

  # The token has to work with `require_oauth_token` as it stands, which resolves
  # the user from `resource_owner_id`. A `client_credentials` grant has none, so
  # such a token would reach `Users.get_user!(nil)` and raise; minting against
  # the account owner is what makes it usable without a special case.
  test "the token resolves to a real user", %{conn: conn, deploy_key: deploy_key} do
    %{"access_token" => token} =
      conn
      |> put_req_header("authorization", "Bearer #{deploy_key}")
      |> post(~p"/api/sprite/token", %{})
      |> json_response(200)

    assert %{resource_owner_id: owner_id} =
             ExOauth2Provider.AccessTokens.get_by_token(token, otp_app: :code_my_spec)

    assert owner_id, "a token with no resource owner cannot pass require_oauth_token"
  end

  test "a key nobody issued buys nothing", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-deploy-key")
      |> post(~p"/api/sprite/token", %{})

    assert conn.status == 401
  end

  test "no credential at all is refused", %{conn: conn} do
    assert post(conn, ~p"/api/sprite/token", %{}).status == 401
  end
end
