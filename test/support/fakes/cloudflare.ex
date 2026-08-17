defmodule CodeMySpecSpex.Fakes.Cloudflare do
  @moduledoc """
  A Cloudflare account whose zone remembers what has been published into it.

  The third fake, and the one whose semantics have already decided the fate of
  a criterion. Two behaviours are modelled because getting them wrong cost real
  work:

    * **A record whose content differs is updated, not duplicated.**
      `ensure_dns_record/5` finds by name and type, adopts when the content
      already matches, and PUTs when it does not. That is why criterion 8027's
      premise could not hold — publishing a *wrong* DKIM value is corrected by
      the step under test, so the domain verifies and the fault it was meant to
      name disappears. A fake that let the wrong value stand would have kept
      that criterion alive on a false premise.

    * **Several TXT records may share a name.** Cloudflare permits it, and it
      is the one DKIM fault the step cannot converge away, because
      `ensure_dns_record/5` finds and updates exactly one. Modelled so the
      difference between "corrected" and "still broken" is real.

  Also here because they are ordinary and have been got wrong: MX priority is
  part of a record's identity (Resend only receives on the lowest, so leaving a
  higher one delivers mail somewhere else silently), and an apex record is
  `@`, which is how a zone file names it and how the sending records are kept
  clear of it (969/8029).

  Not modelled: propagation. Whether a published record *resolves* is a fact
  about the world and belongs to the DNS fake and, ultimately, to the drill.
  """

  alias Plug.Conn

  @doc """
  Fresh account state. One per test.

  A zone is present by default because every criterion that touches DNS starts
  from a domain someone already owns — adopting a zone is the ordinary path and
  registering a new one is the exception (965/8052).
  """
  def new(zone_name \\ "example.com") do
    %{
      account_id: "acct-1",
      zones: [%{"id" => "zone-1", "name" => zone_name}],
      records: %{"zone-1" => []},
      registrar: [zone_name],
      next_id: 1,
      # What the grant is allowed to do. A token can read zones and still
      # refuse to buy a domain, and that gap is criterion 964/7984 — the check
      # reads zones *then* the registrar precisely because reporting the zone
      # read as success would call an under-scoped grant verified.
      scopes: [:zones, :registrar]
    }
  end

  @doc "Narrow the grant, for the criterion about a token that cannot do the job."
  def revoke_scope(agent, scope) do
    Agent.update(agent, fn state -> %{state | scopes: List.delete(state.scopes, scope)} end)
  end

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)

    {status, body} =
      Agent.get_and_update(
        agent,
        &route(conn.method, segments(conn), body_of(conn), conn.query_params, &1)
      )

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp segments(conn) do
    conn.request_path |> String.trim_leading("/client/v4") |> String.split("/", trim: true)
  end

  defp body_of(%{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_of(%{body_params: params}) when is_map(params), do: params
  defp body_of(_), do: %{}

  # -- accounts and zones --

  defp route("GET", ["accounts"], _body, _params, state) do
    {ok([%{"id" => state.account_id, "name" => "spex"}]), state}
  end

  defp route("GET", ["zones"], _body, params, state) do
    {ok(matching_zones(state, params)), state}
  end

  # -- dns records --

  defp route("GET", ["zones", zone, "dns_records"], _body, _params, state) do
    {ok(records(state, zone)), state}
  end

  defp route("POST", ["zones", zone, "dns_records"], body, _params, state) do
    record = %{
      "id" => "rec-#{state.next_id}",
      "zone_id" => zone,
      "name" => body["name"],
      "type" => body["type"],
      "content" => body["content"],
      "ttl" => body["ttl"] || 60,
      "priority" => body["priority"],
      "proxied" => body["proxied"] || false
    }

    {ok(record), put_records(%{state | next_id: state.next_id + 1}, zone, records(state, zone) ++ [record])}
  end

  # The update path. `ensure_dns_record/5` reaches here when a record with this
  # name and type exists but its content differs — which is exactly why a
  # deliberately wrong value cannot be used as a premise: the step corrects it.
  defp route("PUT", ["zones", zone, "dns_records", id], body, _params, state) do
    updated =
      Enum.map(records(state, zone), fn
        %{"id" => ^id} = record -> Map.merge(record, sanitise(body))
        record -> record
      end)

    {ok(Enum.find(updated, &(&1["id"] == id))), put_records(state, zone, updated)}
  end

  defp route("DELETE", ["zones", zone, "dns_records", id], _body, _params, state) do
    {ok(%{"id" => id}),
     put_records(state, zone, Enum.reject(records(state, zone), &(&1["id"] == id)))}
  end

  # -- registrar --

  # Every registrar path goes through the scope gate first, and a grant that
  # does not hold it gets Cloudflare's own refusal. `Credentials.do_check/3`
  # reads zones and *then* the registrar precisely to tell "can read zones"
  # from "can buy a domain" — criterion 964/7984 — so a fake that answered
  # both alike would call an under-scoped grant verified.
  #
  # One gate dispatching onward rather than a clause per path: a top clause
  # matching `["accounts", _, "registrar" | _]` would shadow the ones below it,
  # and the single-domain lookup 965 depends on would never be reached.
  defp route(method, ["accounts", acct, "registrar" | rest], body, params, state) do
    case :registrar in state.scopes do
      true -> registrar(method, [acct | rest], body, params, state)
      false -> {{403, failure(unscoped_message())}, state}
    end
  end

  defp route(method, segments, _body, _params, state) do
    {{501, failure("#{method} /#{Enum.join(segments, "/")} is not modelled by the Cloudflare fake")},
     state}
  end

  # -- helpers --

  defp records(state, zone), do: Map.get(state.records, zone, [])
  defp put_records(state, zone, records), do: %{state | records: Map.put(state.records, zone, records)}

  defp matching_zones(state, %{"name" => name}),
    do: Enum.filter(state.zones, &(&1["name"] == name))

  defp matching_zones(state, _params), do: state.zones

  # Only the fields a caller may change. Without this a PUT could rewrite the
  # id or move a record between zones, and a bug that did so would pass.
  defp sanitise(body), do: Map.take(body, ["name", "type", "content", "ttl", "priority", "proxied"])

  defp unscoped_message do
    "Actor 'com.cloudflare.api.token' requires permission " <>
      "'com.cloudflare.registrar.domain.list' to access requested resource"
  end

  defp registrar("GET", [_acct, "domains"], _body, _params, state) do
    {ok(Enum.map(state.registrar, &%{"name" => &1, "available" => false})), state}
  end

  defp registrar("GET", [_acct, "domains", name], _body, _params, state) do
    # A domain already on the account is an ordinary way in, not an error path
    # (965/8052) — it answers, rather than 404ing, and the step adopts it.
    #
    # A name that is *not* on the account also answers, with less. Verified
    # against the live API and recorded in `Cloudflare.check_domain/2`: the
    # registrar returns `available`, `can_register` and `current_registrar`
    # only for domains it already knows, and for anything else it returns the
    # name and whether the extension is one it sells. That distinction is
    # criterion 7988's whole subject — "what the registrar actually said, and
    # no more" — and 404ing instead made every unknown name an error.
    case name in state.registrar do
      true -> {ok(%{"name" => name, "available" => false}), state}
      false -> {ok(%{"name" => name, "supported_tld" => supported_tld?(name)}), state}
    end
  end

  defp registrar("POST", [_acct, "domains"], body, _params, state) do
    name = body["name"]
    {ok(%{"name" => name}), %{state | registrar: Enum.uniq(state.registrar ++ [name])}}
  end

  # The extensions Cloudflare Registrar sells. `.museum` is not one, which is
  # what makes 965/7993 — "an unsupported extension becomes a dashboard
  # errand" — a real answer rather than a failure.
  defp supported_tld?(name) do
    name |> String.split(".") |> List.last() |> Kernel.in(~w(com net org dev io co ca app))
  end

  defp ok(result), do: {200, %{"success" => true, "errors" => [], "result" => result}}

  defp failure(message),
    do: %{"success" => false, "errors" => [%{"message" => message}], "result" => nil}
end
