defmodule CodeMySpec.Stories.Tools.SetStoryComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import Plug.Conn

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "SetStoryComponent tool" do
    test "executes with valid module_name" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      remote_plug = fn conn ->
        body = remote_plug_body(conn.method, story, component)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      end

      frame = %Frame{
        assigns: %{
          current_scope: scope,
          remote_client_opts: [plug: remote_plug, token: "test-token"]
        }
      }

      params = %{
        story_number: story.number,
        module_name: component.module_name
      }

      response =
        ToolLibrary.run(
          "set_story_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
    end

    test "returns error when story not found" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      remote_plug = fn conn ->
        body = Jason.encode!(%{error: "Story not found"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, body)
      end

      frame = %Frame{
        assigns: %{
          current_scope: scope,
          remote_client_opts: [plug: remote_plug, token: "test-token"]
        }
      }

      params = %{
        story_number: 99_999,
        module_name: component.module_name
      }

      response =
        ToolLibrary.run(
          "set_story_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end

    test "returns error when component not found by module_name" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        story_number: story.number,
        module_name: "NonExistent.Module"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "set_story_component",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp remote_plug_body("POST", story, component) do
    Jason.encode!(%{
      data: %{
        id: story.id,
        title: story.title,
        component_id: component.id,
        priority: story.priority,
        project_id: story.project_id,
        account_id: story.account_id
      }
    })
  end

  # RemoteSync.sync fetches stories list on GET.
  defp remote_plug_body("GET", _story, _component), do: Jason.encode!(%{data: []})
end
