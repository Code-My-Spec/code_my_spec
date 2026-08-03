defmodule CodeMySpec.Migration.ClientTest do
  @moduledoc """
  The sending half of story 991.

  What matters here is the envelope, not the payload — the payload is
  `Migration.export_project/1`, which the 991 spex already drive end to end.
  This pins the three things only the client decides: that the cloud project
  is named by `x-project-id` and never inferred, that a refusal reaches the
  caller in the server's own words, and that nothing is sent at all when the
  caller has not said where it should go.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Migration.Client

  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  defp echo_plug(fun) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fun.(conn, Jason.decode!(body))
    end
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "migrate/2" do
    test "names the cloud project in x-project-id, not from the local project", %{scope: scope} do
      test_pid = self()

      plug =
        echo_plug(fn conn, _payload ->
          send(test_pid, {:headers, Plug.Conn.get_req_header(conn, "x-project-id")})
          send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
          respond(conn, 200, %{"status" => "ok", "migrated" => %{"stories" => 0}})
        end)

      assert {:ok, %{"stories" => 0}} =
               Client.migrate(scope,
                 cloud_project_id: "cloud-side-uuid",
                 token: "tok_123",
                 base_url: "https://example.test",
                 plug: plug
               )

      assert_receive {:headers, ["cloud-side-uuid"]}
      assert_receive {:auth, ["Bearer tok_123"]}
    end

    test "sends the exported graph as the body", %{scope: scope} do
      test_pid = self()

      plug =
        echo_plug(fn conn, payload ->
          send(test_pid, {:payload_keys, payload |> Map.keys() |> Enum.sort()})
          respond(conn, 200, %{"status" => "ok", "migrated" => %{}})
        end)

      assert {:ok, _} =
               Client.migrate(scope,
                 cloud_project_id: "p",
                 token: "t",
                 base_url: "https://example.test",
                 plug: plug
               )

      assert_receive {:payload_keys, keys}
      assert "stories" in keys, "the payload must carry the authored graph"
    end

    test "passes a refusal through in the server's own words", %{scope: scope} do
      plug =
        echo_plug(fn conn, _ ->
          respond(conn, 422, %{
            "status" => "error",
            "reason" => "a paid plan is required before anything moves"
          })
        end)

      assert {:error, {:refused, 422, "a paid plan is required before anything moves"}} =
               Client.migrate(scope,
                 cloud_project_id: "p",
                 token: "t",
                 base_url: "https://example.test",
                 plug: plug
               )
    end

    test "sends nothing when the cloud project was not named", %{scope: scope} do
      plug = echo_plug(fn _conn, _ -> flunk("must not send without a target project") end)

      assert {:error, :cloud_project_id_required} =
               Client.migrate(scope, token: "t", base_url: "https://example.test", plug: plug)
    end
  end
end
