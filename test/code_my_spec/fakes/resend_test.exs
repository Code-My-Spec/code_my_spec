defmodule CodeMySpecSpex.Fakes.ResendTest do
  @moduledoc """
  The three Resend behaviours that cost this project the most, checked at the
  layer where they are cheap.

  Each was learned the expensive way — a night, a recording, or a story's worth
  of confusion — and none could have been learned from a tape, because a tape
  answers with whatever was true on the day it was made.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes.Resend

  setup do
    {:ok, agent} = Agent.start_link(&Resend.new/0)
    %{agent: agent}
  end

  defp request(agent, method, path), do: send_request(agent, method, path, nil)
  defp request(agent, method, path, body), do: send_request(agent, method, path, body)

  defp send_request(agent, method, path, nil), do: Req.request!(req(agent, method, path))

  defp send_request(agent, method, path, body) do
    req(agent, method, path) |> Req.merge(json: body) |> Req.request!()
  end

  defp req(agent, method, path) do
    Req.new(
      method: method,
      url: "https://api.resend.com" <> path,
      plug: &Resend.call(&1, agent)
    )
  end

  defp register(agent, name), do: do_register(agent, %{"name" => name})

  defp register(agent, name, caps),
    do: do_register(agent, %{"name" => name, "capabilities" => caps})

  defp do_register(agent, body) do
    %{body: domain} = request(agent, :post, "/domains", body)
    domain
  end

  describe "verification is a process, not a field" do
    test "a new domain is pending, and its records are not verified", %{agent: agent} do
      %{"id" => id} = register(agent, "mail.example.com")

      assert %{body: %{"status" => "pending", "records" => records}} =
               request(agent, :get, "/domains/#{id}")

      assert Enum.all?(records, &(&1["status"] == "pending"))
    end

    # 969/8026 is "setup waits rather than assuming". Against a tape that claim
    # cannot fail — the recorded answer is whatever it was. Here it can.
    test "it verifies only after being asked to", %{agent: agent} do
      %{"id" => id} = register(agent, "mail.example.com")

      assert %{body: %{"status" => "pending"}} = request(agent, :get, "/domains/#{id}")

      request(agent, :post, "/domains/#{id}/verify")

      assert %{body: %{"status" => "verified", "records" => records}} =
               request(agent, :get, "/domains/#{id}")

      assert Enum.all?(records, &(&1["status"] == "verified"))
    end
  end

  describe "PATCH answers with almost nothing" do
    # This shape cost a night: the code read the PATCH response to confirm
    # receiving was on, and concluded failure on every success.
    test "the patch response carries no capabilities, so a read has to confirm it", %{agent: agent} do
      %{"id" => id} = register(agent, "mail.example.com")

      assert %{body: patched} =
               request(agent, :patch, "/domains/#{id}", %{
                 "capabilities" => %{"sending" => "enabled", "receiving" => "enabled"}
               })

      refute Map.has_key?(patched, "capabilities")

      assert %{body: %{"capabilities" => %{"receiving" => "enabled"}}} =
               request(agent, :get, "/domains/#{id}")
    end
  end

  describe "suppression is account-wide and silent" do
    test "a suppressed address is accepted and never delivered", %{agent: agent} do
      %{"id" => id} = register(agent, "example.com")
      request(agent, :post, "/domains/#{id}/verify")

      Agent.update(agent, &%{&1 | suppressions: ["inbox@example.com"]})

      assert %{status: 200, body: %{"id" => _}} =
               request(agent, :post, "/emails", %{
                 "from" => "hello@example.com",
                 "to" => ["inbox@example.com"]
               })

      # Accepted by the API, and absent from what was actually sent. Nothing in
      # the response says so, which is the difficulty this models.
      assert Agent.get(agent, & &1.sent) == []
    end

    test "clearing the suppression makes the same send land", %{agent: agent} do
      %{"id" => id} = register(agent, "example.com")
      request(agent, :post, "/domains/#{id}/verify")
      Agent.update(agent, &%{&1 | suppressions: ["inbox@example.com"]})

      request(agent, :delete, "/suppressions/inbox@example.com")

      request(agent, :post, "/emails", %{
        "from" => "hello@example.com",
        "to" => ["inbox@example.com"]
      })

      assert [%{"to" => ["inbox@example.com"]}] = Agent.get(agent, & &1.sent)
    end
  end

  describe "capabilities decide whether mail can arrive" do
    test "a sending-only domain is what you get by default", %{agent: agent} do
      %{"id" => id} = register(agent, "example.com")

      assert %{body: %{"capabilities" => %{"receiving" => "disabled"}}} =
               request(agent, :get, "/domains/#{id}")
    end

    test "receiving can be asked for at creation", %{agent: agent} do
      %{"id" => id} =
        register(agent, "example.com", %{"sending" => "enabled", "receiving" => "enabled"})

      assert %{body: %{"capabilities" => %{"receiving" => "enabled"}}} =
               request(agent, :get, "/domains/#{id}")
    end
  end

  describe "inbound is the mirror of sending, and only when receiving is on" do
    # The probe proves an inbox exists by sending to the domain and waiting for
    # Resend to say it arrived. On a receiving-enabled domain it does.
    test "a message to a receiving domain comes back as inbound", %{agent: agent} do
      %{"id" => id} =
        register(agent, "example.com", %{"sending" => "enabled", "receiving" => "enabled"})

      request(agent, :post, "/domains/#{id}/verify")

      request(agent, :post, "/emails", %{
        "from" => "probe@example.com",
        "to" => ["inbox@example.com"],
        "subject" => "knock"
      })

      assert %{body: %{"data" => [%{"subject" => "knock"}]}} =
               request(agent, :get, "/emails/receiving?limit=10")
    end

    # And the case that cost story 974 a night: sending-only accepts the probe,
    # returns an id, and drops it. Nothing distinguishes it at the send.
    test "a sending-only domain accepts the probe and delivers nothing", %{agent: agent} do
      %{"id" => id} = register(agent, "example.com")
      request(agent, :post, "/domains/#{id}/verify")

      assert %{status: 200, body: %{"id" => _}} =
               request(agent, :post, "/emails", %{
                 "from" => "probe@example.com",
                 "to" => ["inbox@example.com"]
               })

      assert %{body: %{"data" => []}} = request(agent, :get, "/emails/receiving?limit=10")
    end
  end

  describe "ordinary shapes" do
    # 965/8052: a domain you already have is a way in, not an error path.
    test "registering the same domain twice hands back the one it has", %{agent: agent} do
      first = register(agent, "example.com")
      second = register(agent, "example.com")

      assert first["id"] == second["id"]
      assert length(Agent.get(agent, & &1.domains)) == 1
    end

    # The list omits records; only the single read carries them. Rendering the
    # panel from the list is what 8025 caught.
    test "the listing omits records and the single read carries them", %{agent: agent} do
      %{"id" => id} = register(agent, "example.com")

      %{body: %{"data" => [listed]}} = request(agent, :get, "/domains")
      refute Map.has_key?(listed, "records")

      %{body: full} = request(agent, :get, "/domains/#{id}")
      assert length(full["records"]) == 3
    end

    test "sending from an unverified domain is refused", %{agent: agent} do
      register(agent, "example.com")

      assert %{status: 403} =
               request(agent, :post, "/emails", %{
                 "from" => "hello@example.com",
                 "to" => ["someone@elsewhere.com"]
               })
    end

    test "an unmodelled path says so", %{agent: agent} do
      assert %{status: 501, body: %{"name" => "not_modelled"}} =
               request(agent, :get, "/audiences")
    end
  end
end
