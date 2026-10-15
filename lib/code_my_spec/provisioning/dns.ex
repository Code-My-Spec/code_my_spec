defmodule CodeMySpec.Provisioning.Dns do
  @moduledoc """
  What a public resolver actually returns for a name.

  - A provider's "verified" is not the record being published: Resend keeps a
    verification long after the record behind it is deleted. So this asks DNS.
  - `:inet_res` (OTP), no DNS dependency.
  - Every failure — timeout, NXDOMAIN, empty — means "not resolving".

  See knowledge/provisioning, "DNS checks".
  """

  alias CodeMySpec.Provisioning.Wait

  require Logger

  @default_timeout 3_000

  @doc """
  Whether `name` resolves to at least one record of `type`.

  `type` is a DNS record type as an atom — `:mx`, `:txt`, `:cname`, `:a`.
  """
  @spec resolves?(String.t(), atom(), keyword()) :: boolean()
  def resolves?(name, type, opts \\ []) do
    lookup(name, type, opts) != []
  end

  @doc """
  Whether `name` resolves to `type` from outside this machine, retrying while
  a freshly written record propagates.

  Asks the zone's own nameservers first and falls back to DNS-over-HTTPS
  (`probe/3`). Unlike `resolves?/3`, the DoH path is an ordinary HTTP request,
  so it records and replays in cassettes.
  """
  @spec resolves_publicly?(String.t(), atom(), keyword()) :: boolean()
  def resolves_publicly?(name, type, opts \\ []) do
    resolution_status(name, type, opts) == :resolves
  end

  @doc """
  Why `name` does not resolve, when it does not.

  `:resolves`, or `{:absent, :cached, seconds_left}`, or `{:absent, :fresh}`.

  A negative answer carries the zone's SOA, whose TTL counts down in a cache;
  a TTL below the SOA minimum means a resolver has been holding the "no" for
  the difference. Only the DoH fallback can return `{:absent, :cached, _}`;
  the authoritative path has no cache.
  """
  @spec resolution_status(String.t(), atom(), keyword()) ::
          :resolves | {:absent, :cached, non_neg_integer()} | {:absent, :fresh}
  def resolution_status(name, type, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 1)
    interval = Keyword.get(opts, :interval_ms, 2_000)

    # `:settle_ms` waits before the first ask: a resolver asked before
    # propagation caches the "no" for the zone's negative TTL and every retry
    # reads that cache. Zero by default.
    case Keyword.get(opts, :settle_ms, 0) do
      settle when is_integer(settle) and settle > 0 -> Wait.sleep(settle)
      _ -> :ok
    end

    Enum.reduce_while(1..attempts, {:absent, :fresh}, fn attempt, _acc ->
      case probe(name, type, opts) do
        {:answers, [_ | _]} ->
          {:halt, :resolves}

        absent when attempt < attempts ->
          Wait.sleep(interval)
          {:cont, absent}

        absent ->
          {:halt, absent}
      end
    end)
  end

  # The zone first, a recursive resolver only if the zone cannot be reached:
  # an authoritative answer reflects a write the instant it lands and never
  # lingers, and the claim is "published", not "some resolver noticed".
  defp probe(name, type, opts) do
    case authoritative_lookup(name, type, opts) do
      {:answers, _} = answers -> answers
      :none -> {:absent, :fresh}
      :unavailable -> doh_lookup(name, type, opts)
    end
  end

  # `:unavailable` whenever something stands in for the world's DNS (fakes,
  # cassettes, an injected `:resolver`): the records live in a stub no real
  # nameserver knows. A configured nameserver (the local fleet) is asked.
  defp authoritative_lookup(name, type, opts) do
    cond do
      configured_nameserver() != nil -> zone_answer(name, type, opts)
      Keyword.has_key?(opts, :resolver) or stubbed_resolver?() -> :unavailable
      true -> zone_answer(name, type, opts)
    end
  end

  defp stubbed_resolver? do
    :code_my_spec |> Application.get_env(__MODULE__, []) |> Keyword.has_key?(:plug)
  end

  @spec zone_answer(String.t(), atom(), keyword()) ::
          {:answers, [String.t()]} | :none | :unavailable
  defp zone_answer(name, type, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case nameserver_addresses(name, timeout) do
      [] -> :unavailable
      servers -> zone_answer(servers, name, type, timeout)
    end
  rescue
    _ -> :unavailable
  end

  defp zone_answer(servers, name, type, timeout) do
    case :inet_res.resolve(
           to_charlist(name),
           :in,
           type,
           resolver_options(servers, timeout),
           timeout
         ) do
      {:ok, record} ->
        case answers(record) do
          [] -> :none
          answers -> {:answers, answers}
        end

      # NXDOMAIN is a fact about the record; anything else is a fact about the
      # asking and must not read as "not published".
      {:error, {:nxdomain, _}} ->
        :none

      {:error, :nxdomain} ->
        :none

      _ ->
        :unavailable
    end
  end

  defp answers(record) do
    record |> :inet_dns.msg(:anlist) |> Enum.map(&(&1 |> :inet_dns.rr(:data) |> format()))
  end

  # Google, then Cloudflare only if Google had nothing: one positive proves the
  # record resolves; one resolver's silence can be a stale cached negative.
  # Asking the second only on empty keeps cassettes byte-identical on the path
  # that already worked. Cloudflare needs the JSON accept header (else 400).
  @doh_resolvers [
    {"https://dns.google/resolve", []},
    {"https://cloudflare-dns.com/dns-query", [accept: "application/dns-json"]}
  ]

  defp doh_lookup(name, type, opts) do
    Enum.reduce_while(@doh_resolvers, {:absent, :fresh}, fn {endpoint, headers}, acc ->
      case doh_query(endpoint, headers, name, type, opts) do
        {:answers, [_ | _]} = answers -> {:halt, answers}
        # A cached negative explains the silence if the other resolver is
        # silent too: "wait for it", not "publish it".
        {:absent, :cached, _} = cached -> {:cont, cached}
        _ -> {:cont, acc}
      end
    end)
  end

  defp doh_query(endpoint, headers, name, type, opts) do
    url = "#{endpoint}?name=#{URI.encode(name)}&type=#{type |> to_string() |> String.upcase()}"

    case req(opts).(url, headers) do
      {:ok, %{status: 200, body: %{"Answer" => answers}}} when is_list(answers) ->
        {:answers, Enum.map(answers, & &1["data"])}

      {:ok, %{status: 200, body: %{} = body}} ->
        negative(body)

      _ ->
        {:absent, :fresh}
    end
  end

  # The SOA's last field is the zone's negative TTL; a cached record's TTL
  # below it means cached, and by how much.
  defp negative(%{"Authority" => [_ | _] = authority}) do
    Enum.find_value(authority, {:absent, :fresh}, fn record ->
      with 6 <- record["type"],
           ttl when is_integer(ttl) <- record["TTL"],
           minimum when is_integer(minimum) <- soa_minimum(record["data"]),
           true <- ttl < minimum do
        {:absent, :cached, ttl}
      else
        _ -> nil
      end
    end)
  end

  defp negative(_body), do: {:absent, :fresh}

  # `ns.example.com. hostmaster.example.com. 2412243971 10000 2400 604800 1800`
  defp soa_minimum(data) when is_binary(data) do
    case data |> String.split() |> List.last() do
      nil ->
        nil

      last ->
        case Integer.parse(last) do
          {minimum, _} -> minimum
          :error -> nil
        end
    end
  end

  defp soa_minimum(_), do: nil

  # Injectable so a spex can drive it through its cassette plug; a one-argument
  # stub is adapted.
  defp req(opts) do
    case Keyword.get(opts, :resolver) do
      nil -> &default_resolver/2
      fun when is_function(fun, 2) -> fun
      fun when is_function(fun, 1) -> fn url, _headers -> fun.(url) end
    end
  end

  defp default_resolver(url, headers) do
    config = Application.get_env(:code_my_spec, __MODULE__, [])

    Req.get(url, Keyword.update(config, :headers, headers, &Keyword.merge(&1, headers)))
  end

  @doc """
  Every record of `type` published for `name`, as strings.

  MX answers come back as `{priority, host}`; the priority is kept because it
  decides whether a receiving host is used at all.
  """
  @spec lookup(String.t(), atom(), keyword()) :: [String.t()]
  def lookup(name, type, opts \\ [])

  # `:inet_res` returns nothing for A (address resolution goes through the
  # system resolver), so A uses `:inet.gethostbyname/1`.
  def lookup(name, :a, _opts) do
    case :inet.gethostbyname(to_charlist(name)) do
      {:ok, {:hostent, _, _, _, _, addrs}} ->
        Enum.map(addrs, &(&1 |> :inet.ntoa() |> List.to_string()))

      _ ->
        []
    end
  end

  # A resolver follows a CNAME, so asking for the CNAME itself can return
  # nothing for a published name; fall back to A.
  def lookup(name, :cname, opts) do
    case do_lookup(name, :cname, opts) do
      [] -> lookup(name, :a, opts)
      records -> records
    end
  end

  def lookup(name, type, opts), do: do_lookup(name, type, opts)

  @doc """
  Ask the zone's own nameservers rather than a recursive resolver.

  A recursive resolver caches the absence of a record, so asking right after
  a publish can report it missing for the whole negative TTL. The
  authoritative servers skip every cache. Falls back to the recursive path
  when the nameservers cannot be found.
  """
  @spec lookup_authoritative(String.t(), atom(), keyword()) :: [String.t()]
  def lookup_authoritative(name, type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case nameserver_addresses(name, timeout) do
      [] ->
        lookup(name, type, opts)

      servers ->
        case :inet_res.resolve(
               to_charlist(name),
               :in,
               type,
               resolver_options(servers, timeout),
               timeout
             ) do
          {:ok, record} -> answers(record)
          _ -> []
        end
    end
  rescue
    _ -> lookup(name, type, opts)
  end

  # The zone apex's nameservers (a subdomain has no NS of its own), resolved
  # to addresses.
  defp nameserver_addresses(name, timeout) do
    case configured_nameserver() do
      nil -> discovered_nameservers(name, timeout)
      server -> [server]
    end
  end

  # TCP only for a configured (fleet) nameserver: colima forwards published
  # ports over an SSH mux that carries TCP, not UDP.
  defp resolver_options(servers, timeout) do
    base = [nameservers: servers, timeout: timeout]

    case configured_nameserver() do
      nil -> base
      _ -> [{:usevc, true} | base]
    end
  end

  # `config :code_my_spec, :dns_nameserver` — a nameserver to ask instead of
  # discovering one, for the local fleet's DNS container. Unset in production.
  defp configured_nameserver do
    case Application.get_env(:code_my_spec, :dns_nameserver) do
      {address, port} when is_tuple(address) and is_integer(port) -> {address, port}
      _ -> nil
    end
  end

  defp discovered_nameservers(name, timeout) do
    zone = name |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

    zone
    |> to_charlist()
    |> :inet_res.lookup(:in, :ns, [], timeout)
    |> Enum.flat_map(fn host ->
      case :inet.gethostbyname(host) do
        {:ok, {:hostent, _, _, _, _, [addr | _]}} -> [{addr, 53}]
        _ -> []
      end
    end)
  end

  defp do_lookup(name, type, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    name
    |> to_charlist()
    |> :inet_res.lookup(:in, type, [], timeout)
    |> Enum.map(&format/1)
  rescue
    # A resolver that raises answered nothing.
    error ->
      Logger.debug("[Dns] #{type} lookup for #{name} failed: #{inspect(error)}")
      []
  end

  @doc """
  The MX records published at a name, as `"priority host"` strings, sorted.

  Sorted so two readings of the same zone compare equal regardless of
  resolver order.
  """
  @spec mx_records(String.t(), keyword()) :: [String.t()]
  def mx_records(name, opts \\ []) do
    name |> lookup(:mx, opts) |> Enum.sort()
  end

  defp format({priority, host}) when is_integer(priority), do: "#{priority} #{to_string(host)}"

  # TXT answers arrive in 255-byte chunks (DKIM keys usually are split);
  # joined to compare with what was published.
  defp format([h | _] = chunks) when is_list(h), do: Enum.map_join(chunks, "", &List.to_string/1)

  defp format(value) when is_list(value), do: List.to_string(value)
  defp format(value) when is_binary(value), do: value

  defp format(value), do: to_string(value)
end
