defmodule CodeMySpec.Provisioning.TeardownApexTest do
  @moduledoc """
  What teardown may delete when the name it was given is the zone apex.

  This is an incident, not a hypothetical. Removing the `prod` environment
  deleted every record in a real zone — the apex A, every subdomain, the MX,
  the DKIM and SPF records — because `prod`'s host *is* the bare domain, and
  the `dns_record` clause removed everything at or under the name it was
  handed. astralbi.com went to zero records during QA of story 849, and
  recovering it took a hand-rebuilt apex plus a separate bug fix before the
  mail records could be republished (ab6029c5).

  `at_or_under?/2` was never wrong. It stops teardown reaching *outside* the
  name it was given, and nothing stopped it reaching everything inside — which,
  for a zone apex, is the whole zone.

  Not async: the Cloudflare stub is installed through application env, which is
  the idiom `CloudflareTest` uses, and two tests setting it at once would race.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.{Cloudflare, Teardown}

  setup do
    Application.put_env(:code_my_spec, Cloudflare, api_token: "test-token", plug: &zone/1)
    on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)

    %{scope: full_scope_fixture()}
  end

  defp prod, do: %{name: "prod", host: "astralbi.com", ip: "159.69.49.203"}
  defp elsewhere, do: %{name: "prod", host: "astralbi.com", ip: "203.0.113.9"}

  # The zone as it stood: an apex A on our box, the customer's own mail records
  # at the apex, and a hostname with something beneath it.
  @records [
    %{"id" => "apex-a", "name" => "astralbi.com", "type" => "A", "content" => "159.69.49.203"},
    %{"id" => "apex-mx", "name" => "astralbi.com", "type" => "MX", "content" => "inbound-smtp"},
    %{
      "id" => "dkim",
      "name" => "resend._domainkey.astralbi.com",
      "type" => "TXT",
      "content" => "p=x"
    },
    %{"id" => "uat-a", "name" => "uat.astralbi.com", "type" => "A", "content" => "49.12.189.154"},
    %{
      "id" => "uat-sub",
      "name" => "x.uat.astralbi.com",
      "type" => "A",
      "content" => "49.12.189.154"
    }
  ]

  describe "a record at the zone apex" do
    test "removes only the apex record aimed at one of our servers", %{scope: scope} do
      record = %{kind: "dns_record", location: "cloudflare/astralbi.com", origin: "created"}

      Teardown.resource(scope, record, project_environments: [prod()])

      assert deleted() == ["apex-a"],
             "expected only the apex A pointing at our own box"
    end

    # The customer's apex, pointing at a site hosted anywhere else. Nothing here
    # belongs to setup, and the subtree beneath it never did either.
    test "leaves an apex we do not own, and everything under it", %{scope: scope} do
      record = %{kind: "dns_record", location: "cloudflare/astralbi.com", origin: "created"}

      Teardown.resource(scope, record, project_environments: [elsewhere()])

      assert deleted() == [],
             "an apex pointing somewhere we do not own is the customer's, and so is the zone"
    end

    # Specifically: the records whose loss was most expensive.
    test "never takes the mail records with it", %{scope: scope} do
      record = %{kind: "dns_record", location: "cloudflare/astralbi.com", origin: "created"}

      Teardown.resource(scope, record, project_environments: [prod()])

      refute "dkim" in deleted(), "DKIM was deleted by an apex teardown"
      refute "apex-mx" in deleted(), "the inbound MX was deleted by an apex teardown"
    end
  end

  # The non-apex path is unchanged and must stay that way: a hostname's subtree
  # is exactly what the dns step writes, and removing the lot is what the
  # clause is for.
  describe "a record below the apex" do
    test "still removes the whole subtree", %{scope: scope} do
      record = %{kind: "dns_record", location: "cloudflare/uat.astralbi.com", origin: "created"}

      Teardown.resource(scope, record, project_environments: [prod()])

      assert Enum.sort(deleted()) == ["uat-a", "uat-sub"],
             "a hostname teardown must still take everything beneath it"
    end
  end

  defp zone(conn), do: reply(conn, conn.method, conn.request_path)

  defp reply(conn, "GET", "/client/v4/zones") do
    json(conn, [%{"id" => "z1", "name" => "astralbi.com"}])
  end

  defp reply(conn, "GET", "/client/v4/zones/z1/dns_records") do
    json(conn, Enum.reject(@records, &(&1["id"] in Process.get(:deleted, []))))
  end

  defp reply(conn, "DELETE", path) do
    id = path |> String.split("/") |> List.last()
    Process.put(:deleted, [id | Process.get(:deleted, [])])
    json(conn, %{})
  end

  defp reply(conn, _method, _path), do: json(conn, [])

  defp json(conn, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"success" => true, "errors" => [], "result" => result}))
  end

  defp deleted, do: Enum.sort(Process.get(:deleted, []))
end
