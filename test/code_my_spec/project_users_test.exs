defmodule CodeMySpec.ProjectUsersTest do
  @moduledoc """
  Unit tests for the ProjectUsers context — the read-through projection of a
  target app's registered users. The outbound Req call is intercepted with
  `Req.Test` (wired via `:project_users_req_plug` in config/test.exs).

  Also covers the "read live, never stored" rule (story 814's dropped spex
  criterion): the context has no schema and re-fetches on every call.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectUsers
  alias CodeMySpec.ProjectUsers.{Page, User}

  defp configured_project(attrs \\ %{}) do
    defaults = %{client_api_url: "https://app.example.com", deploy_key: "test-deploy-key"}
    full_scope_fixture(Map.merge(defaults, attrs)).active_project
  end

  defp stub_json(status, body) do
    Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  describe "list_registered_users/2" do
    test "returns a Page of users parsed from the target app" do
      project = configured_project()

      stub_json(200, %{
        "data" => [
          %{"email" => "a@example.com", "registered_at" => "2026-06-06T18:57:10Z"},
          %{"email" => "b@example.com", "registered_at" => "2026-06-07T03:51:24Z"}
        ],
        "page" => 1,
        "page_size" => 50,
        "total" => 2
      })

      assert {:ok, %Page{users: users, page: 1, page_size: 50, total: 2}} =
               ProjectUsers.list_registered_users(project)

      assert [
               %User{email: "a@example.com", registered_at: %DateTime{}},
               %User{email: "b@example.com"}
             ] = users
    end

    test "returns {:error, :not_configured} when the project has no client config" do
      project = full_scope_fixture(%{client_api_url: nil, deploy_key: nil}).active_project

      assert {:error, :not_configured} = ProjectUsers.list_registered_users(project)
    end

    test "maps a 401 from the target app to {:error, :unauthorized}" do
      project = configured_project()
      stub_json(401, %{"error" => "Invalid deployment key"})

      assert {:error, :unauthorized} = ProjectUsers.list_registered_users(project)
    end

    test "maps a transport failure to {:error, :unreachable}" do
      project = configured_project()

      Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :unreachable} = ProjectUsers.list_registered_users(project)
    end

    test "reads live every call — never caches or stores the users" do
      project = configured_project()

      stub_json(200, %{
        "data" => [%{"email" => "first@example.com"}],
        "page" => 1,
        "page_size" => 50,
        "total" => 1
      })

      assert {:ok, %Page{users: [%User{email: "first@example.com"}]}} =
               ProjectUsers.list_registered_users(project)

      stub_json(200, %{
        "data" => [%{"email" => "second@example.com"}],
        "page" => 1,
        "page_size" => 50,
        "total" => 1
      })

      assert {:ok, %Page{users: [%User{email: "second@example.com"}]}} =
               ProjectUsers.list_registered_users(project)
    end
  end
end
