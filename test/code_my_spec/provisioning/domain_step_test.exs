defmodule CodeMySpec.Provisioning.DomainStepTest do
  @moduledoc """
  d36a6381: the domain step's pause message claimed an unowned name "is
  available" whenever `Cloudflare.owned?/2` returned false — but "not in this
  account" is not "available to register", and the Registrar API cannot
  answer availability for a domain outside the account at all
  (`CloudflareTest`'s "confirmation gate" covers that read on the API
  response directly). This covers the message `Steps.run(:domain, ...)`
  actually pauses with.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.{Cloudflare, Steps}
  alias CodeMySpec.Users.Scope

  @account "6477547f586ec90db2c2a0081dcd98bd"

  defp stub(fun) do
    Application.put_env(:code_my_spec, Cloudflare, api_token: "test-token", plug: fun)
    on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp ok(result), do: %{"success" => true, "errors" => [], "result" => result}

  test "does not tell Sam an unowned domain is available" do
    stub(fn
      %{method: "GET", request_path: "/client/v4/zones"} = conn ->
        json(conn, 200, ok([]))

      %{method: "GET", request_path: "/client/v4/accounts"} = conn ->
        json(conn, 200, ok([%{"id" => @account}]))

      %{method: "GET", request_path: "/client/v4/accounts/" <> _} = conn ->
        json(conn, 200, ok([]))

      %{method: "POST"} = conn ->
        flunk("the domain step registered a domain without confirmation")
        conn
    end)

    scope = %Scope{active_project: %{domain: "google.com"}}

    assert {:paused, message} = Steps.run(:domain, scope, [])

    refute message =~ "is available",
           "not owned by this account is not the same claim as available to register"

    assert message =~ "google.com"
    assert message =~ "not registered to this account"
    assert message =~ ~r/dashboard/i
  end
end
