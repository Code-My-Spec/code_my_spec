defmodule CodeMySpec.Questions.RemoteClientTest do
  @moduledoc """
  Tests for `Questions.RemoteClient` write-through. Asserts that a local-cache
  failure (FK violation, validation, etc.) on the SQLite write-through surfaces
  as `{:error, _}` from the public function — never `{:ok, _}` while the local
  data quietly fails to land.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Questions.RemoteClient
  alias CodeMySpec.Repo

  setup do
    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    {:ok, scope: scope, account_id: account.id}
  end

  describe "create_question/4" do
    test "surfaces local FK violation as {:error, changeset}",
         %{scope: scope, account_id: account_id} do
      missing_story_id = 999_999

      server_question = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account_id,
        "project_id" => scope.active_project_id,
        "story_id" => missing_story_id,
        "text" => "Why?",
        "status" => "open",
        "inserted_at" => "2026-04-28T12:00:00Z",
        "updated_at" => "2026-04-28T12:00:00Z"
      }

      plug = stub_response(201, %{"data" => server_question})

      before_count = Repo.aggregate(Question, :count)

      assert {:error, %Ecto.Changeset{valid?: false}} =
               RemoteClient.create_question(
                 scope,
                 missing_story_id,
                 %{text: "Why?"},
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(Question, :count) == before_count
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
