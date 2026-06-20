defmodule CodeMySpec.Issues.RemoteClientTest do
  @moduledoc """
  Tests for `Issues.RemoteClient`. Asserts the public functions return
  deserialized values (`%Issue{}`, `[%Issue{}]`) — never raw `Req.Response`
  tuples — so callers (`Issues.RemoteSync`, `Issues.sync_resolution_to_remote/2`)
  can pattern-match the same shape as every other remote client.

  HTTP is stubbed with a Req plug — no cassette needed since we're asserting
  on return shape, not wire-format fidelity.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.RemoteClient

  setup do
    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    {:ok, scope: scope, account_id: account.id}
  end

  describe "list_accepted_issues/2" do
    test "returns {:ok, [%Issue{}]} on 200", %{scope: scope, account_id: account_id} do
      issues_payload = [
        issue_payload(%{
          "id" => "11111111-1111-1111-1111-111111111111",
          "title" => "First",
          "severity" => "high",
          "account_id" => account_id
        }),
        issue_payload(%{
          "id" => "22222222-2222-2222-2222-222222222222",
          "title" => "Second",
          "severity" => "low",
          "account_id" => account_id
        })
      ]

      plug = stub_response(200, %{"data" => issues_payload})

      assert {:ok, [%Issue{} = first, %Issue{} = second]} =
               RemoteClient.list_accepted_issues(scope, plug: plug, token: "test")

      assert first.title == "First"
      assert first.severity == :high
      assert second.title == "Second"
      assert second.severity == :low
    end
  end

  describe "update_issue/4" do
    test "returns {:ok, %Issue{}} on 200", %{scope: scope, account_id: account_id} do
      issue_id = "33333333-3333-3333-3333-333333333333"

      server_issue =
        issue_payload(%{
          "id" => issue_id,
          "title" => "Resolved one",
          "status" => "resolved",
          "resolution" => "fixed in v2",
          "account_id" => account_id
        })

      plug = stub_response(200, %{"data" => server_issue})

      assert {:ok, %Issue{} = issue} =
               RemoteClient.update_issue(
                 scope,
                 issue_id,
                 %{status: "resolved", resolution: "fixed in v2"},
                 plug: plug,
                 token: "test"
               )

      assert issue.id == issue_id
      assert issue.status == :resolved
      assert issue.resolution == "fixed in v2"
    end

    test "returns {:error, :not_found} on 404", %{scope: scope} do
      plug = stub_response(404, %{"error" => "not_found"})

      assert {:error, :not_found} =
               RemoteClient.update_issue(
                 scope,
                 "missing-id",
                 %{status: "resolved"},
                 plug: plug,
                 token: "test"
               )
    end

    test "returns {:error, {:validation, body}} on 422", %{scope: scope} do
      plug = stub_response(422, %{"errors" => %{"status" => ["is invalid"]}})

      assert {:error, {:validation, %{"errors" => _}}} =
               RemoteClient.update_issue(
                 scope,
                 "any-id",
                 %{status: "garbage"},
                 plug: plug,
                 token: "test"
               )
    end
  end

  describe "create_issue/3 framework routing" do
    setup do
      prev = Application.get_env(:code_my_spec, :code_my_spec_project_id)
      Application.put_env(:code_my_spec, :code_my_spec_project_id, "cms-project-id")

      on_exit(fn ->
        if prev do
          Application.put_env(:code_my_spec, :code_my_spec_project_id, prev)
        else
          Application.delete_env(:code_my_spec, :code_my_spec_project_id)
        end
      end)

      :ok
    end

    test "framework-scoped issue posts with the configured CodeMySpec project id", %{scope: scope} do
      plug = capturing_plug(self(), 201, %{"data" => issue_payload(%{"scope" => "framework"})})

      assert {:ok, %Issue{}} =
               RemoteClient.create_issue(
                 scope,
                 %{title: "Looping hook", scope: :framework, severity: :high, description: "..."},
                 plug: plug,
                 token: "test"
               )

      assert_received {:project_header, "cms-project-id"}
    end

    test "app-scoped issue keeps the user's active project id", %{scope: scope} do
      plug = capturing_plug(self(), 201, %{"data" => issue_payload(%{})})

      assert {:ok, %Issue{}} =
               RemoteClient.create_issue(
                 scope,
                 %{title: "Bug", scope: :app, severity: :low, description: "..."},
                 plug: plug,
                 token: "test"
               )

      assert_received {:project_header, header}
      assert header == scope.active_project_id
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp capturing_plug(test_pid, status, body) do
    fn conn ->
      header = conn |> Plug.Conn.get_req_header("x-project-id") |> List.first()
      send(test_pid, {:project_header, header})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp stub_response(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp issue_payload(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "title" => "Issue",
        "severity" => "medium",
        "scope" => "app",
        "description" => "an issue",
        "status" => "accepted",
        "resolution" => nil,
        "source" => "qa",
        "story_id" => nil,
        "source_path" => nil,
        "project_id" => nil,
        "account_id" => nil,
        "inserted_at" => "2026-04-25T12:00:00Z",
        "updated_at" => "2026-04-25T12:00:00Z"
      },
      overrides
    )
  end
end
