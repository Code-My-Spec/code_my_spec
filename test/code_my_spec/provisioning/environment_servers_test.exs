defmodule CodeMySpec.Provisioning.EnvironmentServersTest do
  @moduledoc """
  One box per environment, which is what having environments is for.

  The existing coverage injects the step's whole result, so the loop that
  actually creates the servers was never exercised. A drill then produced two
  `-prod` servers and no `-uat`, and the deploy failed with "the provider has
  no such server" — a defect that unit tests could have caught in
  milliseconds and instead cost a ten-minute cloud cycle to notice.

  This asserts on what was asked of the provider, which is the part that
  matters and the part no recording can be wrong about.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Steps

  setup do
    scope = full_scope_fixture()

    on_exit(fn -> Application.delete_env(:code_my_spec, Hetzner) end)

    {:ok, scope: scope}
  end

  # Answers every Hetzner call plausibly and reports what was asked for. The
  # step will not finish — it goes on to reach boxes over SSH — but every
  # server it wanted has been requested by then, which is what this is about.
  defp record_requests(owner) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)

      if conn.method == "POST" and conn.request_path == "/v1/servers" do
        send(owner, {:creating, payload["name"]})
      end

      response =
        cond do
          String.contains?(conn.request_path, "/servers") and conn.method == "GET" ->
            %{"servers" => []}

          String.contains?(conn.request_path, "/servers") ->
            %{"server" => %{"id" => 1, "name" => payload["name"], "location" => %{"name" => "fsn1"}}}

          String.contains?(conn.request_path, "/firewalls") and conn.method == "GET" ->
            %{"firewalls" => []}

          String.contains?(conn.request_path, "/firewalls") ->
            %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}}

          String.contains?(conn.request_path, "/ssh_keys") and conn.method == "GET" ->
            %{"ssh_keys" => []}

          String.contains?(conn.request_path, "/ssh_keys") ->
            %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}}

          String.contains?(conn.request_path, "/networks") and conn.method == "GET" ->
            %{"networks" => []}

          true ->
            %{"network" => %{"id" => 4, "name" => payload["name"]}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(response))
    end

    Application.put_env(:code_my_spec, Hetzner, api_token: "test-token", plug: plug)
  end

  test "asks for one server per environment, named for it", ctx do
    record_requests(self())

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    # `prod` and `uat` are the rows a project starts with. Two servers, two
    # names — the drill asked for `-prod` twice and never for `-uat`, so the
    # environment it was meant to deploy simply did not exist.
    assert length(names) == 2,
           "expected one server per environment, got #{inspect(names)}"

    assert Enum.any?(names, &String.ends_with?(&1, "-prod"))
    assert Enum.any?(names, &String.ends_with?(&1, "-uat"))

    assert names == Enum.uniq(names),
           "the same box was requested twice — one environment has no server at all"
  end

  defp collect_names(acc) do
    receive do
      {:creating, name} -> collect_names([name | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
