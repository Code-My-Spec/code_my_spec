defmodule CodeMySpecWeb.StoriesControllerTest do
  use CodeMySpecTest.ConnCase

  import CodeMySpec.{UsersFixtures, StoriesFixtures, ComponentsFixtures}

  setup %{conn: conn} do
    scope = full_preferences_fixture()
    oauth_app = create_oauth_application()

    # Create user-associated access token directly in database
    access_token_value =
      :crypto.strong_rand_bytes(32) |> Base.encode64() |> String.replace(~r/[^a-zA-Z0-9]/, "")

    # Insert access token with user association
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

    # Create authenticated connection with Bearer token
    conn =
      put_req_header(conn, "authorization", "Bearer #{access_token_value}")
      |> assign(:current_scope, scope)

    %{conn: conn, scope: scope, access_token: access_token_value, oauth_app: oauth_app}
  end

  # Helper function to create OAuth application fixture
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

    # Insert directly without changeset since the OAuth schema doesn't expose it
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

  describe "index/2" do
    test "returns list of stories", %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      conn = get(conn, ~p"/api/stories")

      response_data = json_response(conn, 200)["data"]
      assert is_list(response_data)
      assert Enum.any?(response_data, fn s -> s["id"] == story.id end)
    end
  end

  describe "show/2" do
    test "shows story when valid", %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      conn = get(conn, ~p"/api/stories/#{story.id}")

      response_data = json_response(conn, 200)["data"]
      assert response_data["id"] == story.id
      assert response_data["title"] == story.title
      assert response_data["description"] == story.description
      assert response_data["status"] == to_string(story.status)
    end

    test "returns 404 for non-existent story", %{conn: conn} do
      conn = get(conn, ~p"/api/stories/99999")
      assert json_response(conn, 404)
    end
  end

  describe "create/2" do
    test "creates story with valid params", %{conn: conn} do
      story_params = %{
        title: "New Story",
        description: "Story description",
        criteria: [%{description: "criterion 1"}, %{description: "criterion 2"}],
        status: "in_progress"
      }

      conn = post(conn, ~p"/api/stories", story: story_params)

      assert %{"data" => story_data} = json_response(conn, 201)
      assert story_data["title"] == "New Story"
      assert story_data["description"] == "Story description"
      assert story_data["acceptance_criteria"] == ["criterion 1", "criterion 2"]
      assert story_data["status"] == "in_progress"
    end

    test "returns error with invalid params", %{conn: conn} do
      story_params = %{
        title: nil,
        description: nil
      }

      conn = post(conn, ~p"/api/stories", story: story_params)

      assert json_response(conn, 422)
    end
  end

  describe "update/2" do
    test "updates story with valid params", %{conn: conn, scope: scope} do
      story = story_fixture(scope)

      update_params = %{
        title: "Updated Title",
        description: "Updated description"
      }

      conn = put(conn, ~p"/api/stories/#{story.id}", story: update_params)

      assert %{"data" => story_data} = json_response(conn, 200)
      assert story_data["id"] == story.id
      assert story_data["title"] == "Updated Title"
      assert story_data["description"] == "Updated description"
    end

    test "returns 404 for non-existent story", %{conn: conn} do
      update_params = %{title: "Updated"}

      conn = put(conn, ~p"/api/stories/99999", story: update_params)
      assert json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "deletes story when valid", %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      conn = delete(conn, ~p"/api/stories/#{story.id}")

      assert json_response(conn, 200)["data"]["id"] == story.id

      # Verify story is deleted
      assert CodeMySpec.Stories.get_story(scope, story.id) == nil
    end

    test "returns 404 for non-existent story", %{conn: conn} do
      conn = delete(conn, ~p"/api/stories/99999")
      assert json_response(conn, 404)
    end
  end

  describe "set_component/2" do
    test "sets component for story", %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      component = component_fixture(scope)

      conn =
        post(conn, ~p"/api/stories/#{story.id}/set-component", component_id: component.id)

      assert %{"data" => story_data} = json_response(conn, 200)
      assert story_data["component_id"] == component.id
    end

    test "returns 404 for non-existent story", %{conn: conn, scope: scope} do
      component = component_fixture(scope)

      conn = post(conn, ~p"/api/stories/99999/set-component", component_id: component.id)
      assert json_response(conn, 404)
    end
  end

  describe "bulk_set_component/2" do
    test "links many stories in one call", %{conn: conn, scope: scope} do
      story1 = story_fixture(scope)
      story2 = story_fixture(scope)
      component_a = component_fixture(scope)
      component_b = component_fixture(scope)

      links = [
        %{"story_id" => story1.id, "component_id" => component_a.id},
        %{"story_id" => story2.id, "component_id" => component_b.id}
      ]

      conn = post(conn, ~p"/api/stories/bulk-set-component", links: links)

      assert %{"data" => stories} = json_response(conn, 200)
      assert length(stories) == 2
      by_id = Map.new(stories, fn s -> {s["id"], s["component_id"]} end)
      assert by_id[story1.id] == component_a.id
      assert by_id[story2.id] == component_b.id
    end

    test "later link wins when a story appears twice (surface-overwrites-context)",
         %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      context = component_fixture(scope)
      surface = component_fixture(scope)

      links = [
        %{"story_id" => story.id, "component_id" => context.id},
        %{"story_id" => story.id, "component_id" => surface.id}
      ]

      conn = post(conn, ~p"/api/stories/bulk-set-component", links: links)

      assert %{"data" => _} = json_response(conn, 200)
      assert CodeMySpec.Stories.get_story(scope, story.id).component_id == surface.id
    end

    test "rolls back the entire batch when any story is missing",
         %{conn: conn, scope: scope} do
      story = story_fixture(scope, %{component_id: nil})
      component = component_fixture(scope)

      links = [
        %{"story_id" => story.id, "component_id" => component.id},
        %{"story_id" => 99_999, "component_id" => component.id}
      ]

      conn = post(conn, ~p"/api/stories/bulk-set-component", links: links)

      assert %{"story_id" => 99_999} = json_response(conn, 404)
      assert CodeMySpec.Stories.get_story(scope, story.id).component_id == nil
    end
  end

  describe "clear_component/2" do
    test "clears component from story", %{conn: conn, scope: scope} do
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      conn = post(conn, ~p"/api/stories/#{story.id}/clear-component")

      assert %{"data" => story_data} = json_response(conn, 200)
      assert story_data["component_id"] == nil
    end

    test "returns 404 for non-existent story", %{conn: conn} do
      conn = post(conn, ~p"/api/stories/99999/clear-component")
      assert json_response(conn, 404)
    end
  end

  describe "list_project_stories/2" do
    test "returns list of project stories", %{conn: conn, scope: scope} do
      story = story_fixture(scope)
      conn = get(conn, ~p"/api/stories-list/project")

      response_data = json_response(conn, 200)["data"]
      assert is_list(response_data)
      assert Enum.any?(response_data, fn s -> s["id"] == story.id end)
    end
  end

  describe "list_unsatisfied_stories/2" do
    test "returns list of unsatisfied stories", %{conn: conn, scope: scope} do
      # Create a story without a component (unsatisfied)
      story = story_fixture(scope, %{component_id: nil})
      conn = get(conn, ~p"/api/stories-list/unsatisfied")

      response_data = json_response(conn, 200)["data"]
      assert is_list(response_data)
      assert Enum.any?(response_data, fn s -> s["id"] == story.id end)
    end
  end

  describe "list_component_stories/2" do
    test "returns list of stories for a component", %{conn: conn, scope: scope} do
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      conn = get(conn, ~p"/api/stories-list/component/#{component.id}")

      response_data = json_response(conn, 200)["data"]
      assert is_list(response_data)
      assert Enum.any?(response_data, fn s -> s["id"] == story.id end)
    end
  end
end
