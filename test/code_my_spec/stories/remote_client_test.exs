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

        if titles != [] do
          first = hd(titles)
          # `list_story_titles/2` returns atom-keyed maps to match the
          # StoriesRepository contract (so callers like StoriesMapper can
          # pattern-match the same shape against either impl).
          assert Map.has_key?(first, :id)
          assert Map.has_key?(first, :title)
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
    # NOTE: a successful-create test for the test env was previously written
    # against `create_story_success` but only passed because a `rescue`
    # in `upsert_story_locally` silently swallowed the test-env-only NOT
    # NULL violation on `first_version_id` / `current_version_id`. Story 669
    # killed that rescue. In production CLI envs the local stories table
    # has neither NOT NULL nor FK on the version columns, so the upsert
    # succeeds. Re-create that happy-path test only when local fixture
    # support for PaperTrail versions is available, or split the public
    # function into HTTP + cache layers.

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

  describe "write-through error propagation" do
    # When the local SQLite cache write fails (here: a `[title, project_id]`
    # uniqueness collision), the public function must surface `{:error, _}` —
    # never `{:ok, _}` while the local data quietly fails to land. This is
    # the readiness-gate-looks-broken bug from Story 669 in miniature.
    test "surfaces local validation failure as {:error, changeset}", %{token: token} do
      # The shared `setup` block overrides `active_project_id` to a hardcoded
      # cassette UUID that doesn't exist in the test DB; for stub-plug tests
      # like this one we need the live fixture-created project so writes can
      # actually round-trip through Postgres.
      real_scope = CodeMySpec.UsersFixtures.full_scope_fixture()

      story_a =
        CodeMySpec.StoriesFixtures.story_fixture(real_scope, %{
          title: "Duplicate Title",
          description: "first"
        })

      story_b =
        CodeMySpec.StoriesFixtures.story_fixture(real_scope, %{
          title: "Other Title",
          description: "second"
        })

      server_story = %{
        "id" => story_b.id,
        "title" => story_a.title,
        "description" => "second",
        "acceptance_criteria" => [],
        "criteria" => [],
        "status" => "in_progress",
        "priority" => 1,
        "locked_at" => nil,
        "lock_expires_at" => nil,
        "locked_by" => nil,
        "project_id" => real_scope.active_project.id,
        "component_id" => nil,
        "account_id" => real_scope.active_account.id,
        "tags" => [],
        "inserted_at" => "2026-04-28T12:00:00Z",
        "updated_at" => "2026-04-28T12:00:00Z"
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => server_story}))
      end

      assert {:error, %Ecto.Changeset{valid?: false}} =
               RemoteClient.update_story(
                 real_scope,
                 story_b,
                 %{title: "Duplicate Title"},
                 plug: plug,
                 token: token
               )
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
