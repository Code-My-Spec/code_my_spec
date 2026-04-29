defmodule CodeMySpec.AcceptanceCriteria.RemoteClientTest do
  @moduledoc """
  Tests for `AcceptanceCriteria.RemoteClient` write-through. Asserts that a
  local-cache failure (FK violation, validation, etc.) on the SQLite
  write-through surfaces as `{:error, _}` from the public function — never
  `{:ok, _}` while the local data quietly fails to land.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.AcceptanceCriteria.RemoteClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story

  setup do
    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    {:ok, scope: scope, account_id: account.id}
  end

  describe "create_criterion/4" do
    test "surfaces local FK violation as {:error, changeset}",
         %{scope: scope, account_id: _account_id} do
      missing_story_id = 999_999
      story = %Story{id: missing_story_id}

      server_criterion = %{
        "id" => 12345,
        "description" => "Orphan criterion",
        "body" => nil,
        "kind" => "happy_path",
        "verified" => false,
        "verified_at" => nil,
        "story_id" => missing_story_id,
        "project_id" => scope.active_project_id,
        "rule_id" => nil,
        "inserted_at" => "2026-04-28T12:00:00Z",
        "updated_at" => "2026-04-28T12:00:00Z"
      }

      plug = stub_response(201, %{"data" => server_criterion})

      before_count = Repo.aggregate(Criterion, :count)

      assert {:error, %Ecto.Changeset{valid?: false}} =
               RemoteClient.create_criterion(
                 scope,
                 story,
                 %{description: "Orphan criterion", kind: :happy_path},
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(Criterion, :count) == before_count
    end
  end

  defp stub_response(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end
end
