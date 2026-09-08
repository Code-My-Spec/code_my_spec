defmodule CodeMySpecSpex.Fakes.Resend do
  @moduledoc """
  A Resend account with a memory, and with the three behaviours that cost this
  project the most time.

  Like the Hetzner fake, this answers from accumulated state rather than from a
  tape. What makes Resend the harder one is that its state has a *lifecycle*,
  and every place we got it wrong was a place a recording could not have taught
  us:

    * **Verification is a process, not a field.** A domain is `pending` when
      registered and becomes `verified` only after `POST /domains/:id/verify`
      and a poll. Criterion 8026 is precisely "setup waits rather than
      assuming", and against a tape that claim is unfalsifiable — the recorded
      answer is whatever it was on the day.

    * **`PATCH /domains/:id` returns almost nothing.** It answers
      `{"object":"domain","id":"…"}` with no capabilities, so code that reads
      the PATCH response to confirm receiving was enabled concludes it failed —
      on every success. That cost a night, and the fix was a confirming `GET`.
      Modelled here so the confirming read stays necessary.

    * **Suppression is account-wide.** An address that bounced is suppressed
      for the whole account, not per domain, so the next probe to it is
      accepted by the API and never delivered. Silent, and identical to
      success from the caller's side.

  Capabilities are creation-only in the sense that matters: `POST /domains`
  takes them, and a domain made sending-only cannot receive until it is
  patched. Story 974's probes were accepted and dropped for exactly that
  reason.

  Reality claims — that a message actually arrives, that DNS actually resolves
  — cannot be faked and belong in the drill. See
  `test/spex/TESTING_PROVISIONING.md`.
  """

  alias CodeMySpec.Utils.MapAccess
  alias Plug.Conn

  @doc "Fresh account state. One per test."
  def new do
    %{domains: [], suppressions: [], webhooks: [], received: [], sent: [], next_id: 1}
  end

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)

    {status, body} =
      Agent.get_and_update(agent, &route(conn.method, path(conn), body_of(conn), &1))

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp path(conn), do: conn.request_path

  defp body_of(%{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_of(%{body_params: params}) when is_map(params), do: params
  defp body_of(_), do: %{}

  # -- domains --

  defp route("GET", "/domains", _body, state) do
    {{200, %{"data" => Enum.map(state.domains, &summary/1)}}, state}
  end

  defp route("POST", "/domains", body, state) do
    name = body["name"]

    case Enum.find(state.domains, &(&1["name"] == name)) do
      nil ->
        domain = new_domain(name, body["capabilities"], state.next_id)

        {{201, summary(domain)},
         %{state | domains: state.domains ++ [domain], next_id: state.next_id + 1}}

      existing ->
        # Registering a domain twice is an ordinary way in, not an error path
        # (8052) — the provider hands back the one it has.
        {{200, summary(existing)}, state}
    end
  end

  defp route("GET", "/domains/" <> id, _body, state) do
    with_domain(state, id, fn domain -> {{200, full(domain)}, state} end)
  end

  # The lifecycle. A verify moves `pending` to `verified`, and only then do the
  # records report verified — which is what a criterion about *waiting* has to
  # be able to observe not having happened yet.
  defp route("POST", "/domains/" <> rest, _body, state) do
    id = String.replace_suffix(rest, "/verify", "")

    with_domain(state, id, fn domain ->
      verified =
        domain
        |> Map.put("status", "verified")
        |> Map.put("records", Enum.map(domain["records"], &Map.put(&1, "status", "verified")))

      {{200, summary(verified)}, replace(state, verified)}
    end)
  end

  # Deliberately minimal, because the real one is: `{"object":"domain","id":…}`
  # with no capabilities. Code that reads this response to confirm the patch
  # took will conclude it failed on every success, which is why the caller does
  # a confirming GET.
  defp route("PATCH", "/domains/" <> id, body, state) do
    with_domain(state, id, fn domain ->
      caps = capabilities(body["capabilities"])

      # The record set follows the capability. Enabling receiving is what makes
      # Resend ask for an apex MX, and the inbound step publishes what it is
      # asked for — so a fake that changed the capability without the record
      # would report a receiving domain with nothing to publish.
      patched =
        domain
        |> Map.put("capabilities", caps)
        |> Map.put("records", merge_records(domain["records"], caps))

      {{200, %{"object" => "domain", "id" => id}}, replace(state, patched)}
    end)
  end

  defp route("DELETE", "/domains/" <> id, _body, state) do
    {{200, %{"object" => "domain", "deleted" => true}},
     %{state | domains: Enum.reject(state.domains, &(&1["id"] == id))}}
  end

  # -- sending, and the suppression that silently swallows it --

  defp route("POST", "/emails", body, state) do
    to = body["to"] |> List.wrap() |> List.first()

    cond do
      to in state.suppressions ->
        # Accepted, and never delivered. The API says yes; the message goes
        # nowhere. Nothing in the response distinguishes this from a send that
        # will arrive, which is the whole difficulty.
        {{200, %{"id" => "suppressed-#{state.next_id}"}}, %{state | next_id: state.next_id + 1}}

      not sending_domain?(state, to, body["from"]) ->
        {{403, %{"name" => "validation_error", "message" => "domain is not verified"}}, state}

      true ->
        id = "msg-#{state.next_id}"

        # Loopback. A message addressed to a domain this account can *receive*
        # on comes back through `GET /emails/receiving`, which is how the
        # inbound probe proves an inbox exists at all: setup sends to the
        # domain and then waits for Resend to say it arrived.
        #
        # Only for receiving-enabled domains, which is the distinction story
        # 974 spent a night on — a sending-only domain accepts the probe,
        # returns an id, and drops it. That is modelled by this clause not
        # matching.
        received = deliver_inbound(state, to, body, id)

        {{200, %{"id" => id}},
         %{
           state
           | sent: state.sent ++ [Map.put(body, "id", id)],
             received: received,
             next_id: state.next_id + 1
         }}
    end
  end

  # -- inbound --

  defp route("GET", "/emails/receiving", _body, state) do
    {{200, %{"data" => state.received}}, state}
  end

  defp route("GET", "/emails/receiving/" <> id, _body, state) do
    case Enum.find(state.received, &(&1["id"] == id)) do
      nil -> {{404, not_found()}, state}
      message -> {{200, message}, state}
    end
  end

  # -- suppressions: account-wide, which is the point --

  defp route("GET", "/suppressions", _body, state) do
    data = Enum.map(state.suppressions, &%{"id" => &1, "email" => &1, "reason" => "bounce"})
    {{200, %{"data" => data}}, state}
  end

  defp route("DELETE", "/suppressions/" <> id, _body, state) do
    {{200, %{"deleted" => true}},
     %{state | suppressions: Enum.reject(state.suppressions, &(&1 == id))}}
  end

  # -- webhooks --

  defp route("GET", "/webhooks", _body, state) do
    {{200, %{"data" => state.webhooks}}, state}
  end

  defp route("POST", "/webhooks", body, state) do
    stored = %{
      "id" => "hook-#{state.next_id}",
      "endpoint" => body["endpoint"],
      "events" => body["events"] || [],
      "status" => "enabled"
    }

    # Real Resend returns `signing_secret` only from this create response,
    # never from list/get — stored is what a later GET/list sees again, and
    # it deliberately doesn't carry it, so an adopted (not freshly created)
    # webhook in a test is exactly as secret-less as the real thing. 04349864.
    created = Map.put(stored, "signing_secret", "whsec_fake#{state.next_id}")

    {{201, created}, %{state | webhooks: state.webhooks ++ [stored], next_id: state.next_id + 1}}
  end

  defp route("PATCH", "/webhooks/" <> id, body, state) do
    hooks =
      Enum.map(state.webhooks, fn
        %{"id" => ^id} = hook -> Map.merge(hook, body)
        hook -> hook
      end)

    {{200, %{"object" => "webhook", "id" => id}}, %{state | webhooks: hooks}}
  end

  defp route("DELETE", "/webhooks/" <> id, _body, state) do
    {{200, %{"deleted" => true}},
     %{state | webhooks: Enum.reject(state.webhooks, &(&1["id"] == id))}}
  end

  defp route(method, path, _body, state) do
    {{501,
      %{
        "name" => "not_modelled",
        "message" => "#{method} #{path} is not modelled by the Resend fake"
      }}, state}
  end

  # -- helpers --

  defp new_domain(name, capabilities, seq) do
    caps = capabilities(capabilities)

    %{
      "id" => "dom-#{seq}",
      "name" => name,
      "status" => "pending",
      # Resend stamps one and the setup page reads it as the domain's
      # verification time — `data-verified-at`, which 969/8026 pairs with the
      # step's own completion to assert setup waited rather than assumed.
      # Absent, the page rendered an empty attribute and the criterion read it
      # as "verification was never timestamped" on a domain that had verified.
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "capabilities" => caps,
      "records" => records_for(name, caps)
    }
  end

  # Sending-only unless asked otherwise, matching `ensure_domain/2`. A domain
  # made without `receiving` accepts probes and drops them, which is what 974
  # spent a night on.
  defp capabilities(nil), do: %{"sending" => "enabled", "receiving" => "disabled"}

  defp capabilities(caps) when is_map(caps) do
    %{
      "sending" => to_string(MapAccess.get(caps, :sending, "enabled")),
      "receiving" => to_string(MapAccess.get(caps, :receiving, "disabled"))
    }
  end

  # The 2026 record set: one DKIM TXT, an MX and an SPF TXT on `send` — and,
  # when the domain may receive, a fourth at the apex labelled `Receiving`.
  #
  # That fourth record is the whole of the inbound step: it publishes what
  # Resend asks for, and a domain that cannot receive asks for nothing, so the
  # step reports "no MX record … there is nothing to publish". Modelling
  # sending-only domains without it is what makes 974's premise real rather
  # than assumed.
  #
  # Pending until verified, because a criterion about waiting needs to see them
  # not verified yet.
  defp records_for(name, capabilities) do
    sending = [
      %{
        "record" => "DKIM",
        "name" => "resend._domainkey",
        "type" => "TXT",
        "value" => "p=MIGfMA0GCSq#{:erlang.phash2(name)}",
        "status" => "pending"
      },
      %{
        "record" => "SPF",
        "name" => "send",
        "type" => "MX",
        "value" => "feedback-smtp.us-east-1.amazonses.com",
        "priority" => 10,
        "status" => "pending"
      },
      %{
        "record" => "SPF",
        "name" => "send",
        "type" => "TXT",
        "value" => "v=spf1 include:amazonses.com ~all",
        "status" => "pending"
      }
    ]

    sending ++ receiving_records(capabilities)
  end

  defp receiving_records(%{"receiving" => "enabled"}) do
    [
      %{
        "record" => "Receiving",
        "name" => "",
        "type" => "MX",
        "value" => "inbound-smtp.us-east-1.amazonaws.com",
        "priority" => 10,
        "status" => "pending"
      }
    ]
  end

  defp receiving_records(_capabilities), do: []

  # Keep the records already there — their verification status is state a
  # criterion may have moved — and add or drop the receiving one to match.
  defp merge_records(existing, capabilities) do
    sending = Enum.reject(existing, &(&1["record"] == "Receiving"))
    kept = Enum.filter(existing, &(&1["record"] == "Receiving"))

    case {receiving_records(capabilities), kept} do
      {[], _} -> sending
      {_new, [_ | _] = already} -> sending ++ already
      {new, []} -> sending ++ new
    end
  end

  # The list endpoint omits `records`; only the single-domain read carries
  # them. Rendering from the list produced a page that knew a domain was
  # verified and could not say which records made it so, which is the whole of
  # criterion 8025.
  defp summary(domain), do: Map.drop(domain, ["records"])
  defp full(domain), do: domain

  defp replace(state, domain) do
    %{
      state
      | domains: Enum.map(state.domains, &if(&1["id"] == domain["id"], do: domain, else: &1))
    }
  end

  defp with_domain(state, id, fun) do
    case Enum.find(state.domains, &(&1["id"] == id)) do
      nil -> {{404, not_found()}, state}
      domain -> fun.(domain)
    end
  end

  defp sending_domain?(_state, _to, nil), do: false

  defp sending_domain?(state, _to, from) do
    host = from |> to_string() |> String.split("@") |> List.last()

    Enum.any?(state.domains, fn d ->
      d["status"] == "verified" and String.ends_with?(host, d["name"])
    end)
  end

  # A message to a domain this account receives on comes back as inbound mail.
  # Anywhere else it is simply sent, and nothing arrives here — which is the
  # sending-only case, and the reason 974's probes were accepted and dropped.
  defp deliver_inbound(state, to, body, id) do
    case receiving_domain(state, to) do
      nil ->
        state.received

      _domain ->
        state.received ++
          [
            %{
              "id" => "in-#{id}",
              "to" => [to],
              "from" => body["from"],
              "subject" => body["subject"],
              "text" => body["text"] || body["html"],
              "created_at" => "2026-01-01T00:00:00.000Z"
            }
          ]
    end
  end

  defp receiving_domain(state, to) do
    host = to |> to_string() |> String.split("@") |> List.last()

    Enum.find(state.domains, fn d ->
      d["capabilities"]["receiving"] == "enabled" and String.ends_with?(host, d["name"])
    end)
  end

  defp not_found, do: %{"name" => "not_found", "message" => "Domain not found"}
end
