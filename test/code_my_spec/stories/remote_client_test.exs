defmodule CodeMySpec.Stories.RemoteClientTest do
  @moduledoc """
  Tests for Stories RemoteClient using ReqCassette.

  ## Recording cassettes

  1. Start the Phoenix server: `mix phx.server`
  2. Generate token: `mix get_johns10_token`
  3. Export: `export OAUTH_TOKEN="your_token_here"`
  4. Delete cassettes to re-record: `rm test/cassettes/stories/*.json`
  5. Run: `mix test test/code_my_spec/stories/remote_client_test.exs`

  Subsequent runs replay from cassettes — no server needed.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import ReqCassette

  alias CodeMySpec.Stories.RemoteClient
  alias CodeMySpec.Stories.Story

  @cassette_dir "test/cassettes/stories"
  @project_id "708492f9-454e-482f-a2eb-be64f0356b87"

  setup do
    # Override base_url to hit local dev server during recording
    prev = Application.get_env(:code_my_spec, :base_url)
    Application.put_env(:code_my_spec, :base_url, "http://localhost:4000")
    on_exit(fn -> Application.put_env(:code_my_spec, :base_url, prev) end)

    # Build scope with real project ID so the x-project-id header matches
    scope =
      full_scope_fixture()
      |> Map.put(:active_project_id, @project_id)

    token = System.get_env("OAUTH_TOKEN", "test-token")

    {:ok, scope: scope, token: token}
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      filter_request_headers: ["authorization"]
    ]
  end

  describe "list_stories/2" do
    test "returns deserialized stories", %{scope: scope, token: token} do
      with_cassette "list_stories", cassette_opts(), fn plug ->
        stories = RemoteClient.list_stories(scope, plug: plug, token: token)
        assert is_list(stories)
        assert Enum.all?(stories, &match?(%Story{}, &1))
      end
    end
  end

  describe "list_project_stories/2" do
    test "returns {:ok, stories}", %{scope: scope, token: token} do
      with_cassette "list_project_stories", cassette_opts(), fn plug ->
        assert {:ok, stories} =
                 RemoteClient.list_project_stories(scope, plug: plug, token: token)

        assert is_list(stories)
        assert Enum.all?(stories, &match?(%Story{}, &1))
      end
    end
  end

  describe "list_project_stories_paginated/2" do
    test "returns {stories, total}", %{scope: scope, token: token} do
      with_cassette "list_project_stories_paginated", cassette_opts(), fn plug ->
        {stories, total} =
          RemoteClient.list_project_stories_paginated(scope,
            plug: plug,
            token: token,
            limit: 5,
            offset: 0
          )

        assert is_list(stories)
        assert is_integer(total)
        assert length(stories) <= 5
        assert Enum.all?(stories, &match?(%Story{}, &1))
      end
    end

    test "passes search param", %{scope: scope, token: token} do
      with_cassette "list_project_stories_paginated_search", cassette_opts(), fn plug ->
        {stories, total} =
          RemoteClient.list_project_stories_paginated(scope,
            plug: plug,
            token: token,
            search: "nonexistent_xyzzy"
          )

        assert is_list(stories)
        assert is_integer(total)
      end
    end
  end

  describe "list_story_titles/2" do
    test "returns title maps", %{scope: scope, token: token} do
      with_cassette "list_story_titles", cassette_opts(), fn plug ->
        titles = RemoteClient.list_story_titles(scope, plug: plug, token: token)
        assert is_list(titles)

        if length(titles) > 0 do
          first = hd(titles)
          assert Map.has_key?(first, "id")
          assert Map.has_key?(first, "title")
        end
      end
    end
  end

  describe "list_project_stories_by_priority/2" do
    test "returns stories", %{scope: scope, token: token} do
      with_cassette "list_project_stories_by_priority", cassette_opts(), fn plug ->
        stories =
          RemoteClient.list_project_stories_by_priority(scope, plug: plug, token: token)

        assert is_list(stories)
        assert Enum.all?(stories, &match?(%Story{}, &1))
      end
    end
  end

  describe "list_unsatisfied_stories/2" do
    test "returns stories without components", %{scope: scope, token: token} do
      with_cassette "list_unsatisfied_stories", cassette_opts(), fn plug ->
        stories = RemoteClient.list_unsatisfied_stories(scope, plug: plug, token: token)
        assert is_list(stories)
        assert Enum.all?(stories, &match?(%Story{}, &1))
      end
    end
  end

  describe "list_component_stories/3" do
    test "returns stories for a component", %{scope: scope, token: token} do
      with_cassette "list_component_stories", cassette_opts(), fn plug ->
        stories =
          RemoteClient.list_component_stories(
            scope,
            "00000000-0000-0000-0000-000000000000",
            plug: plug,
            token: token
          )

        assert is_list(stories)
      end
    end
  end

  describe "get_story/3" do
    test "returns nil when not found", %{scope: scope, token: token} do
      with_cassette "get_story_not_found", cassette_opts(), fn plug ->
        assert is_nil(RemoteClient.get_story(scope, 999_999, plug: plug, token: token))
      end
    end
  end

  describe "get_story!/3" do
    test "raises when not found", %{scope: scope, token: token} do
      with_cassette "get_story_bang_not_found", cassette_opts(), fn plug ->
        assert_raise Ecto.NoResultsError, fn ->
          RemoteClient.get_story!(scope, 999_999, plug: plug, token: token)
        end
      end
    end
  end

  describe "create_story/3" do
    test "returns {:ok, story} on success", %{scope: scope, token: token} do
      with_cassette "create_story_success", cassette_opts(), fn plug ->
        attrs = %{
          title: "RemoteClient Test Story",
          description: "Created by remote_client_test",
          status: :in_progress
        }

        assert {:ok, %Story{} = story} =
                 RemoteClient.create_story(scope, attrs, plug: plug, token: token)

        assert story.title == "RemoteClient Test Story"
        assert story.description == "Created by remote_client_test"
      end
    end

    test "returns {:error, changeset} on validation failure", %{scope: scope, token: token} do
      with_cassette "create_story_error", cassette_opts(), fn plug ->
        attrs = %{title: nil, description: nil}

        assert {:error, %Ecto.Changeset{valid?: false}} =
                 RemoteClient.create_story(scope, attrs, plug: plug, token: token)
      end
    end
  end

  describe "update_story/4" do
    test "returns {:error, :not_found} when missing", %{scope: scope, token: token} do
      with_cassette "update_story_not_found", cassette_opts(), fn plug ->
        story = %Story{id: 999_999, account_id: scope.active_account.id}

        assert {:error, :not_found} =
                 RemoteClient.update_story(scope, story, %{title: "x"},
                   plug: plug,
                   token: token
                 )
      end
    end
  end

  describe "delete_story/3" do
    test "returns {:error, :not_found} when missing", %{scope: scope, token: token} do
      with_cassette "delete_story_not_found", cassette_opts(), fn plug ->
        story = %Story{id: 999_999, account_id: scope.active_account.id}

        assert {:error, :not_found} =
                 RemoteClient.delete_story(scope, story, plug: plug, token: token)
      end
    end
  end

  describe "set_story_component/4" do
    test "returns {:error, :not_found} when story missing", %{scope: scope, token: token} do
      with_cassette "set_story_component_not_found", cassette_opts(), fn plug ->
        story = %Story{id: 999_999, account_id: scope.active_account.id}

        assert {:error, :not_found} =
                 RemoteClient.set_story_component(scope, story, "comp-1",
                   plug: plug,
                   token: token
                 )
      end
    end
  end

  describe "clear_story_component/3" do
    test "returns {:error, :not_found} when story missing", %{scope: scope, token: token} do
      with_cassette "clear_story_component_not_found", cassette_opts(), fn plug ->
        story = %Story{id: 999_999, account_id: scope.active_account.id}

        assert {:error, :not_found} =
                 RemoteClient.clear_story_component(scope, story, plug: plug, token: token)
      end
    end
  end

  describe "deserialize_story/1" do
    test "deserializes all fields" do
      data = %{
        "id" => 1,
        "title" => "Test Story",
        "description" => "A test",
        "acceptance_criteria" => ["c1"],
        "criteria" => [
          %{
            "id" => 10,
            "description" => "c1",
            "verified" => false,
            "verified_at" => nil,
            "story_id" => 1,
            "project_id" => "p1",
            "inserted_at" => "2026-01-01T00:00:00Z",
            "updated_at" => "2026-01-01T00:00:00Z"
          }
        ],
        "status" => "in_progress",
        "priority" => 1,
        "locked_at" => nil,
        "lock_expires_at" => nil,
        "locked_by" => nil,
        "project_id" => "p1",
        "component_id" => "comp-1",
        "account_id" => "a1",
        "tags" => [%{"id" => 100, "name" => "epic"}],
        "inserted_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z"
      }

      story = RemoteClient.deserialize_story(data)

      assert %Story{
               id: 1,
               title: "Test Story",
               status: :in_progress,
               component_id: "comp-1"
             } = story

      assert length(story.criteria) == 1
      assert length(story.tags) == 1
    end
  end
end
