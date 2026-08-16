defmodule CodeMySpecSpex.Fakes.CloudflareTest do
  @moduledoc """
  The zone behaviours that have already decided a criterion's fate.

  Two of these are the reason 969/8027 was dropped: a record whose content
  differs is corrected by the step under test, and the one fault it cannot
  converge away is a second record sharing a name. A fake that got either
  wrong would have kept that criterion alive on a premise that cannot hold.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes.Cloudflare

  setup do
    {:ok, agent} = Agent.start_link(fn -> Cloudflare.new("astralbi.com") end)
    %{agent: agent}
  end

  defp request(agent, method, path), do: send_request(agent, method, path, nil)
  defp request(agent, method, path, body), do: send_request(agent, method, path, body)

  defp send_request(agent, method, path, nil), do: Req.request!(req(agent, method, path))

  defp send_request(agent, method, path, body),
    do: req(agent, method, path) |> Req.merge(json: body) |> Req.request!()

  defp req(agent, method, path) do
    Req.new(
      method: method,
      url: "https://api.cloudflare.com/client/v4" <> path,
      plug: &Cloudflare.call(&1, agent)
    )
  end

  defp publish(agent, attrs) do
    %{body: %{"result" => record}} = request(agent, :post, "/zones/zone-1/dns_records", attrs)
    record
  end

  defp listed(agent) do
    %{body: %{"result" => records}} = request(agent, :get, "/zones/zone-1/dns_records")
    records
  end

  test "a published record is in the zone afterwards", %{agent: agent} do
    publish(agent, %{"name" => "send.astralbi.com", "type" => "TXT", "content" => "v=spf1"})

    assert [%{"name" => "send.astralbi.com", "content" => "v=spf1"}] = listed(agent)
  end

  # The behaviour that killed 8027's premise. A wrong value does not stay
  # wrong: the step finds the record and corrects it.
  test "updating a record replaces its content rather than adding a second", %{agent: agent} do
    record = publish(agent, %{"name" => "resend._domainkey", "type" => "TXT", "content" => "wrong"})

    request(agent, :put, "/zones/zone-1/dns_records/#{record["id"]}", %{
      "name" => "resend._domainkey",
      "type" => "TXT",
      "content" => "p=correct"
    })

    assert [%{"content" => "p=correct"}] = listed(agent)
  end

  # And the one fault it cannot converge away, because `ensure_dns_record/5`
  # finds and updates exactly one.
  test "two TXT records may share a name", %{agent: agent} do
    publish(agent, %{"name" => "resend._domainkey", "type" => "TXT", "content" => "p=first"})
    publish(agent, %{"name" => "resend._domainkey", "type" => "TXT", "content" => "p=second"})

    assert length(listed(agent)) == 2
  end

  test "a deleted record leaves the zone", %{agent: agent} do
    record = publish(agent, %{"name" => "send", "type" => "TXT", "content" => "v=spf1"})
    request(agent, :delete, "/zones/zone-1/dns_records/#{record["id"]}")

    assert listed(agent) == []
  end

  # 969/8029: the sending records go on `send`, and the apex MX Sam already has
  # must still be there afterwards.
  test "publishing sending records leaves an apex MX alone", %{agent: agent} do
    publish(agent, %{"name" => "@", "type" => "MX", "content" => "inbound.example", "priority" => 10})
    publish(agent, %{"name" => "send", "type" => "MX", "content" => "feedback-smtp", "priority" => 10})

    apex = Enum.filter(listed(agent), &(&1["name"] == "@"))
    assert [%{"content" => "inbound.example"}] = apex
  end

  # Resend receives on the lowest-priority MX only, so priority is part of
  # what a record *is* — a fake that dropped it would let a bug that leaves a
  # higher one in place pass.
  test "priority is kept on an MX record", %{agent: agent} do
    publish(agent, %{"name" => "send", "type" => "MX", "content" => "feedback", "priority" => 10})

    assert [%{"priority" => 10}] = listed(agent)
  end

  test "a zone is found by name", %{agent: agent} do
    %{body: %{"result" => [zone]}} = request(agent, :get, "/zones?name=astralbi.com")
    assert zone["name"] == "astralbi.com"

    %{body: %{"result" => none}} = request(agent, :get, "/zones?name=elsewhere.com")
    assert none == []
  end

  # 965/8052: a domain already on the account answers, so the step adopts
  # rather than offering to buy.
  test "a domain already on the account is found, not missing", %{agent: agent} do
    assert %{status: 200, body: %{"result" => %{"available" => false}}} =
             request(agent, :get, "/accounts/acct-1/registrar/domains/astralbi.com")
  end

  # And a name the account does not hold answers too, with less. Verified
  # against the live API and recorded in `Cloudflare.check_domain/2`: full
  # detail only for domains it knows, and for anything else the name plus
  # whether the extension is one it sells. 965/7988 asserts exactly that
  # difference — "what the registrar actually said, and no more" — which a 404
  # turned into an error path.
  test "a name nobody owns answers with the extension, not a 404", %{agent: agent} do
    assert %{status: 200, body: %{"result" => result}} =
             request(agent, :get, "/accounts/acct-1/registrar/domains/never-owned.com")

    assert result["supported_tld"] == true
    refute Map.has_key?(result, "available")
  end

  # 965/7993: an extension Cloudflare does not sell is a dashboard errand, not
  # a failure.
  test "an unsupported extension is reported as unsupported", %{agent: agent} do
    assert %{status: 200, body: %{"result" => result}} =
             request(agent, :get, "/accounts/acct-1/registrar/domains/sams-new-thing.museum")

    assert result["supported_tld"] == false
  end

  test "an unmodelled path says so", %{agent: agent} do
    assert %{status: 501, body: %{"success" => false}} = request(agent, :get, "/user/tokens")
  end
end
