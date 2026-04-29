defmodule CodeMySpec.BddRules.RemoteClientTest do
  @moduledoc """
  Tests for `BddRules.RemoteClient` write-through. Asserts that a local-cache
  failure (FK violation, validation, etc.) on the SQLite write-through surfaces
  as `{:error, _}` from the public function — never `{:ok, _}` while the local
  data quietly fails to land.

  Story 669 motivation: the `BddRulesChecker` reads local, so a silent
  write-through failure makes the readiness gate look broken even though the
  remote write succeeded.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.BddRules.RemoteClient
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Repo

  setup do
    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    {:ok, scope: scope, account_id: account.id}
  end

  describe "create_rule/4" do
    test "surfaces local FK violation as {:error, changeset}",
         %{scope: scope, account_id: account_id} do
      # Server returns 201 referencing a story_id that does not exist locally.
      # The write-through Repo.insert hits the `assoc_constraint(:story)` and
      # the public function must return {:error, _} — proving the agent will
      # see a real error rather than a silent local-cache miss.
      missing_story_id = 999_999

      server_rule = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account_id,
        "project_id" => scope.active_project_id,
        "story_id" => missing_story_id,
        "statement" => "Orphan rule",
        "inserted_at" => "2026-04-28T12:00:00Z",
        "updated_at" => "2026-04-28T12:00:00Z"
      }

      plug = stub_response(201, %{"data" => server_rule})

      before_count = Repo.aggregate(Rule, :count)

      assert {:error, %Ecto.Changeset{valid?: false}} =
               RemoteClient.create_rule(
                 scope,
                 missing_story_id,
                 %{statement: "Orphan rule"},
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(Rule, :count) == before_count
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
