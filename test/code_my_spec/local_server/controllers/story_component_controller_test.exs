defmodule CodeMySpec.LocalServer.Controllers.StoryComponentControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{UsersFixtures, StoriesFixtures, ComponentsFixtures}
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.LocalServer.Controllers.StoryComponentController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  describe "set/1" do
    test "links a story to a component by module name", %{scope: scope} do
      story = story_fixture(scope)
      component = component_fixture(scope, %{module_name: "MyApp.Accounts"})

      remote_plug = fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/set-component")

        body =
          Jason.encode!(%{
            data: %{
              id: story.id,
              title: story.title,
              component_id: component.id,
              status: "#{story.status}",
              priority: story.priority,
              project_id: story.project_id,
              account_id: story.account_id
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      conn =
        build_conn(scope, %{"story_id" => story.id, "module_name" => "MyApp.Accounts"})
        |> assign(:remote_client_opts, plug: remote_plug, token: "test-token")

      conn = StoryComponentController.set(conn)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["story_id"] == story.id
      assert body["component_id"] == component.id
      assert body["module_name"] == "MyApp.Accounts"
      assert body["story_title"] == story.title
    end

    test "returns 404 when story not found", %{scope: scope} do
      component_fixture(scope, %{module_name: "MyApp.Accounts"})

      conn =
        build_conn(scope, %{
          "story_id" => 999_999_999,
          "module_name" => "MyApp.Accounts"
        })

      conn = StoryComponentController.set(conn)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Story not found"
    end

    test "returns 404 when component module name not found", %{scope: scope} do
      story = story_fixture(scope)

      conn =
        build_conn(scope, %{
          "story_id" => story.id,
          "module_name" => "MyApp.DoesNotExist"
        })

      conn = StoryComponentController.set(conn)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Component not found"
    end
  end

  defp build_conn(scope, body_params) do
    conn(:post, "/api/stories/set-component", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
