defmodule CodeMySpec.Provisioning.DnsVerifyTest do
  @moduledoc """
  Whether the dns step's state comes from the zone or from nowhere.

  There was no `verify(:dns, …)` clause, so dns fell to the catch-all and
  always reported absent. A step whose records existed and resolved therefore
  read `not_started` after any page load: the mount re-verifies, and
  `{:ok, :absent}` overwrote a perfectly good `done` without asking Cloudflare
  anything. Criterion 2007 asks that state be checked against the provider
  rather than remembered, and assumed-absent is neither (44905320).

  Not async: the Cloudflare stub installs through application env, the idiom
  `CloudflareTest` uses, and two tests setting it at once would race.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.{Cloudflare, EnvironmentRepository, Steps}

  setup do
    scope = full_scope_fixture()
    {:ok, _} = Projects.update_project(scope, scope.active_project, %{domain: "astralbi.com"})

    %{scope: %{scope | active_project: %{scope.active_project | domain: "astralbi.com"}}}
  end

  defp stub(records) do
    Application.put_env(:code_my_spec, Cloudflare,
      api_token: "test-token",
      plug: fn conn -> reply(conn, conn.request_path, records) end
    )

    on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)
  end

  defp reply(conn, "/client/v4/zones", _records) do
    json(conn, [%{"id" => "z1", "name" => "astralbi.com"}])
  end

  defp reply(conn, "/client/v4/zones/z1/dns_records", records), do: json(conn, records)
  defp reply(conn, _path, _records), do: json(conn, [])

  defp json(conn, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"success" => true, "errors" => [], "result" => result})
    )
  end

  defp uat_at(ip) do
    %{"id" => "r1", "name" => "uat.astralbi.com", "type" => "A", "content" => ip}
  end

  defp seed_uat(scope, ip) do
    {:ok, _} =
      EnvironmentRepository.put(scope, "uat", %{
        host: "uat.astralbi.com",
        server_name: "p-uat",
        ip: ip
      })

    :ok
  end

  describe "a record that is there and points at our server" do
    test "reads satisfied, so a completed step stays completed", %{scope: scope} do
      seed_uat(scope, "159.69.49.203")
      stub([uat_at("159.69.49.203")])

      assert {:ok, :satisfied, resources} = Steps.verify(:dns, scope, [])

      assert Enum.any?(resources, &(&1.location == "cloudflare/uat.astralbi.com")),
             "a satisfied dns verify must report the record it found"
    end
  end

  describe "a record that is not what this project put there" do
    # The dangerous direction. A record left from an earlier build points at an
    # address the project no longer holds, and calling that satisfied is how a
    # name goes on resolving to a machine somebody else was given.
    test "reads absent when it points somewhere else", %{scope: scope} do
      seed_uat(scope, "159.69.49.203")
      stub([uat_at("5.161.239.73")])

      assert {:ok, :absent} = Steps.verify(:dns, scope, [])
    end

    test "reads absent when the record is gone entirely", %{scope: scope} do
      seed_uat(scope, "159.69.49.203")
      stub([])

      assert {:ok, :absent} = Steps.verify(:dns, scope, [])
    end
  end

  describe "before there is anything to check" do
    # An environment with no address has no record to look for, and calling it
    # unsatisfied would be right but useless — this is the state every project
    # is in before the server step runs.
    test "reads absent when no environment has an address", %{scope: scope} do
      {:ok, _} = EnvironmentRepository.put(scope, "uat", %{host: "uat.astralbi.com"})
      stub([])

      assert {:ok, :absent} = Steps.verify(:dns, scope, [])
    end
  end
end
