defmodule CodeMySpecWeb.DeviceControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Intake

  # A laptop's own path: a real OAuth access token, the same credential
  # `Client.Http.announce/3` sends once the harness has traded up from its
  # bootstrap deploy key (see `CmsHarness.Device.credential/0`). Unlike a
  # sprite, a laptop is never pinned to one project by a deploy key, so this
  # is the only credential it ever holds.
  setup %{conn: conn} do
    scope = full_preferences_fixture()

    access_token_value =
      :crypto.strong_rand_bytes(32) |> Base.encode64() |> String.replace(~r/[^a-zA-Z0-9]/, "")

    oauth_app = create_oauth_application()

    {1, [_token]} =
      CodeMySpec.Repo.insert_all(
        "oauth_access_tokens",
        [
          %{
            token: access_token_value,
            resource_owner_id: scope.user.id,
            application_id: oauth_app.id,
            scopes: "read write",
            expires_in: 7200,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        returning: [:id, :token, :resource_owner_id]
      )

    conn = put_req_header(conn, "authorization", "Bearer #{access_token_value}")

    %{conn: conn, scope: scope}
  end

  defp create_oauth_application(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Test Application",
        uid: "test-client-#{System.unique_integer([:positive])}",
        secret: "test-secret-#{:crypto.strong_rand_bytes(32) |> Base.encode64()}",
        redirect_uri: "https://example.com/callback",
        scopes: "read write"
      })

    {1, [app]} =
      CodeMySpec.Repo.insert_all(
        "oauth_applications",
        [
          Map.merge(attrs, %{
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          })
        ],
        returning: [:id, :name, :uid, :secret, :redirect_uri, :scopes]
      )

    struct(CodeMySpec.Oauth.Application, app)
  end

  # Mirrors `IntakeTest`'s `converted_local_plan/1` — a plan that chose
  # `location: :local` and converted, so its project exists but no harness
  # has minted it a working copy yet.
  defp converted_local_plan(scope) do
    token = Intake.new_session_token()
    {:ok, plan} = Intake.start_plan(token)
    {:ok, plan} = Intake.describe(plan, "a booking tool for hair salons")

    {:ok, plan} =
      Intake.answer(plan, %{needs_sign_in: true, separate_copies: true, who_uses: "salon owners"})

    {:ok, plan} = Intake.generate_plan(plan)
    {:ok, plan} = Intake.confirm_tier(plan, %{location: :local})

    {:ok, plan} =
      Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Widget Tracker"})

    {:ok, plan} = Intake.convert(plan, scope)
    plan
  end

  describe "POST /api/devices — pending_local_projects" do
    test "a laptop is offered a converted local plan with no checkout yet", %{
      conn: conn,
      scope: scope
    } do
      plan = converted_local_plan(scope)

      conn = post(conn, ~p"/api/devices", %{"kind" => "local", "hostname" => "johns-laptop"})

      assert %{"pending_local_projects" => [pending]} = json_response(conn, 200)
      assert pending["id"] == plan.project_id
      assert pending["name"] == "Widget Tracker"
      assert is_binary(pending["deploy_key"])
    end

    test "a project a harness already onboarded is no longer offered", %{
      conn: conn,
      scope: scope
    } do
      plan = converted_local_plan(scope)
      project_scope = %{scope | active_project_id: plan.project_id}

      {:ok, _copy} =
        CodeMySpec.WorkingCopies.issue(project_scope, nil,
          label: "onboarded by a harness",
          device: CodeMySpec.DevicesFixtures.device_fixture(project_scope)
        )

      conn = post(conn, ~p"/api/devices", %{"kind" => "local", "hostname" => "johns-laptop"})

      assert %{"pending_local_projects" => []} = json_response(conn, 200)
    end

    test "a sprite (kind: cloud) is never offered a pending local project", %{
      conn: conn,
      scope: scope
    } do
      _plan = converted_local_plan(scope)

      conn = post(conn, ~p"/api/devices", %{"kind" => "cloud", "hostname" => "a-sprite"})

      assert %{"pending_local_projects" => []} = json_response(conn, 200)
    end

    test "a user with no active account is never offered a pending local project", %{
      conn: conn
    } do
      other_scope = full_preferences_fixture()
      _plan = converted_local_plan(other_scope)

      # A freshly registered user with no preferences row yet — `Scope.for_user/1`
      # leaves `active_account_id` nil for exactly this case.
      fresh_user = user_fixture()

      access_token_value =
        :crypto.strong_rand_bytes(32) |> Base.encode64() |> String.replace(~r/[^a-zA-Z0-9]/, "")

      oauth_app = create_oauth_application()

      {1, [_token]} =
        CodeMySpec.Repo.insert_all(
          "oauth_access_tokens",
          [
            %{
              token: access_token_value,
              resource_owner_id: fresh_user.id,
              application_id: oauth_app.id,
              scopes: "read write",
              expires_in: 7200,
              inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }
          ],
          returning: [:id, :token, :resource_owner_id]
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{access_token_value}")
        |> post(~p"/api/devices", %{"kind" => "local", "hostname" => "a-fresh-laptop"})

      assert %{"pending_local_projects" => []} = json_response(conn, 200)
    end
  end
end
