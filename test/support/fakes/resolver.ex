defmodule CodeMySpecSpex.Fakes.Resolver do
  @moduledoc """
  A public resolver that answers from the zone the fake Cloudflare holds.

  This is the piece that closes the loop. `Dns.resolves_publicly?/3` asks
  Cloudflare's and Google's DNS-over-HTTPS endpoints whether a name is visible
  to the internet, and the dns step refuses to call itself done until one of
  them says yes — for a good reason, recorded in `Dns`: everything after dns
  reaches the *name*, so a record that is written but not resolving fails the
  eight steps behind it in ways that point nowhere near the cause.

  Under fakes the record is written into `Fakes.Cloudflare` and no resolver on
  the internet has ever heard of it, so the step correctly reported "no public
  resolver returns it" and setup stopped there. Answering from the same state
  Cloudflare was written into is what makes publication mean visibility, which
  is what it means in the world.

  It shares the Cloudflare fake's agent rather than keeping state of its own —
  two stores would let a spex publish into one and resolve from the other, and
  a resolver that answers for records nobody published is worth nothing.
  """

  alias Plug.Conn

  @doc "The plug arg is the *Cloudflare* fake's agent — deliberately shared."
  def call(conn, cloudflare_agent) do
    conn = Conn.fetch_query_params(conn)
    name = conn.query_params["name"] |> to_string() |> String.trim_trailing(".")
    type = conn.query_params["type"] |> to_string() |> String.upcase()

    answers =
      cloudflare_agent
      |> Agent.get(& &1)
      |> matching(name, type)

    body =
      case answers do
        [] -> %{"Status" => 3, "Question" => [%{"name" => name, "type" => type}]}
        found -> %{"Status" => 0, "Answer" => found}
      end

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(200, Jason.encode!(body))
  end

  defp matching(state, name, type) do
    zones = Map.new(state.zones, &{&1["id"], &1["name"]})

    state.records
    |> Enum.flat_map(fn {zone_id, records} ->
      Enum.map(records, &{Map.get(zones, zone_id, ""), &1})
    end)
    |> Enum.filter(fn {zone, record} -> answers?(record, zone, name, type) end)
    |> Enum.map(fn {_zone, record} -> answer(record, name) end)
  end

  # Cloudflare stores a record's name either fully qualified or as the bare
  # label, depending on which call wrote it, so both are matched — a resolver
  # that only understood one of the two would report half the zone missing and
  # send the reader looking at the dns step rather than at this file.
  defp answers?(record, zone, name, type) do
    String.upcase(to_string(record["type"])) == type and
      qualified(record["name"], zone) == name
  end

  defp qualified(record_name, zone) do
    case to_string(record_name) do
      "@" -> zone
      "" -> zone
      n -> if String.ends_with?(n, zone), do: n, else: "#{n}.#{zone}"
    end
  end

  defp answer(record, name) do
    %{
      "name" => name,
      "type" => type_number(String.upcase(to_string(record["type"]))),
      "TTL" => record["ttl"] || 300,
      "data" => data(record)
    }
  end

  # An MX answer carries its priority in the data, which is how the real
  # endpoints return it and how `Dns` parses it back out.
  defp data(%{"type" => type} = record) when is_binary(type) do
    case String.upcase(type) do
      "MX" -> "#{record["priority"] || 10} #{record["content"]}"
      _ -> to_string(record["content"])
    end
  end

  defp data(record), do: to_string(record["content"])

  defp type_number("A"), do: 1
  defp type_number("CNAME"), do: 5
  defp type_number("MX"), do: 15
  defp type_number("TXT"), do: 16
  defp type_number(_), do: 1
end
