defmodule CodeMySpec.Provisioning.Dns do
  @moduledoc """
  What a public resolver actually returns for a name.

  ## Why this exists rather than trusting the provider

  Resend reports whether *it* has verified a record. That is a different claim
  from the record being published, and the two come apart in the direction
  that matters: a provider holds a verification long after the record behind
  it is deleted, so a domain reads "verified" while its DKIM is gone and mail
  is being rejected somewhere else.

  Criterion 8025 asks that records "resolve from a public resolver", and
  criterion 8029 asks whether setup disturbed mail that was already arriving.
  Neither question can be answered from the provider's own record list — one
  is about the zone, the other about what a third party sees. So this asks a
  resolver.

  ## No new dependency

  `:inet_res` is in OTP. A DNS library would be a dependency added to ask a
  question the runtime already answers.

  ## Failures are "not resolving", not errors

  A lookup that times out, NXDOMAINs, or returns nothing all mean the same
  thing to a caller: the record is not visible. Distinguishing them would
  invite handling that has nowhere useful to go — the answer is the same in
  every case, and it is the answer the criteria ask for.
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
  Whether `name` resolves to `type` **according to a public resolver over
  HTTPS**, retrying while a freshly written record propagates.

  `resolves?/3` asks the local stub resolver through `:inet`, which is right
  for a person at a terminal and wrong for two reasons here: a system call
  cannot be recorded, so a spex would hit real DNS on replay and fail once the
  record it asserted on had been torn down; and a just-written record does not
  resolve on the first ask, so a single lookup reports a working record as
  broken.

  DNS-over-HTTPS is an ordinary HTTP request, so it records and replays like
  every other provider call, and it genuinely leaves this machine — which is
  the claim being made: the record resolves for somebody who is not us.
  """
  @spec resolves_publicly?(String.t(), atom(), keyword()) :: boolean()
  def resolves_publicly?(name, type, opts \\ []) do
    resolution_status(name, type, opts) == :resolves
  end

  @doc """
  Why `name` does not resolve, when it does not.

  `:resolves`, or `{:absent, :cached, seconds_left}`, or `{:absent, :fresh}`.

  The distinction is the difference between a record that is missing and a
  record that is published while a resolver still remembers it was not. Both
  read as "no answer", and reporting the second as the first cost most of an
  evening: `c7995.astralbi.com` was written, `dig @1.1.1.1` returned it, and
  the dns step said no public resolver returns it.

  A negative answer carries the zone's SOA in its authority section, and the
  SOA's own TTL is what is counting down in a cache. Fresh from the
  authoritative server it arrives at the zone's minimum — 1800s on
  astralbi.com — so a TTL *below* that minimum means some resolver has been
  holding this answer for the difference. That is the whole test.

  It matters most for names that cycle. Every spex label and every drill
  domain is created, destroyed and created again, and a resolver asked during
  the gap keeps saying no for half an hour after the record is back — longer
  than any step is willing to wait, so no amount of retrying helps and the
  honest thing is to say which it is.

  All of which describes a recursive resolver, and is why this asks the zone's
  own nameservers first — see `probe/3`. `{:absent, :cached, _}` can only come
  back from the fallback now, because the authoritative path has no cache to
  read a stale answer out of.
  """
  @spec resolution_status(String.t(), atom(), keyword()) ::
          :resolves | {:absent, :cached, non_neg_integer()} | {:absent, :fresh}
  def resolution_status(name, type, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 1)
    interval = Keyword.get(opts, :interval_ms, 2_000)

    # Before the first ask, not only between asks. A resolver that is asked
    # for a name in the seconds before it propagates caches the "no" for the
    # zone's negative TTL — half an hour — and every retry after that reads
    # its own cache entry rather than the record. So the step poisons itself
    # with its own first question, and retrying harder cannot help.
    #
    # Measured: c7995.astralbi.com was created, checked immediately, and
    # reported unresolvable through fifteen retries over 75s. An hour later
    # the same name answered from the same resolver, unchanged.
    #
    # Zero by default, because a caller that already waited should not wait
    # again, and the callers that need it say so.
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

  # The zone first, a recursive resolver only if the zone cannot be reached.
  #
  # Everything above about cached negatives is a description of recursive
  # resolvers, and the fix for all of it is to stop asking them. The zone's own
  # nameservers answer from the zone: a record that exists reads as existing the
  # instant it is written, and one that does not never lingers. Asking a cache
  # whether a record we just published exists is asking the wrong party — the
  # claim the step makes is "this is published", not "some resolver has noticed
  # yet", and only the first of those is about setup (8fb98c23).
  #
  # An authoritative "no" is therefore conclusive in a way a recursive "no"
  # never was, so it does not need the cached/fresh distinction — that
  # distinction exists only to explain a cache's answer, and there is no cache
  # in this path. It stays for the fallback, which still talks to one.
  defp probe(name, type, opts) do
    case authoritative_lookup(name, type, opts) do
      {:answers, _} = answers -> answers
      :none -> {:absent, :fresh}
      :unavailable -> doh_lookup(name, type, opts)
    end
  end

  # `:unavailable` rather than an answer whenever something is standing in for
  # the world's DNS. Under fakes and cassettes the records live in an agent no
  # nameserver has heard of, and a spex that published into that agent is
  # asking whether *it* holds the record; reaching past the stand-in to real
  # nameservers would answer a question nobody asked, and answer it "no".
  #
  # An explicitly configured nameserver is the exception, because naming one is
  # already the instruction to ask it — that is how the fleet points this at its
  # own DNS container.
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

      # The zone answering "no such name" is a fact about the record. Anything
      # else — a timeout, a refusal, a server that would not talk to us — is a
      # fact about the asking, and saying "not published" on the strength of it
      # would be the same false negative in a new place.
      {:error, {:nxdomain, _}} -> :none
      {:error, :nxdomain} -> :none
      _ -> :unavailable
    end
  end

  defp answers(record) do
    record |> :inet_dns.msg(:anlist) |> Enum.map(&(&1 |> :inet_dns.rr(:data) |> format()))
  end

  # Google first, then Cloudflare, and only if Google had nothing to say.
  #
  # One resolver's answer is enough to prove a record resolves for somebody who
  # is not us — that is the whole claim, and a positive is a positive. One
  # resolver's *silence* proves nothing of the kind, and treating it as proof is
  # what this used to do.
  #
  # Measured, on a record that had just been written: `dig @1.1.1.1` and the
  # system resolver both returned the address while `dig @8.8.8.8` returned
  # nothing — a negative answer cached from before the record existed. The
  # record was published, correct, and visible to most of the internet.
  #
  # That matters more than it used to. `dns_verification/2` is now fatal when
  # nothing resolves, so a single stale cache at one provider could halt a run
  # whose DNS was right, and the message would name the record as missing. It
  # also produced the fourth wrong sentence in the TLS diagnostic in a week,
  # all of the same family: a conclusion drawn from one probe that could not
  # distinguish the cases it was deciding between.
  #
  # Asking the second only after the first comes up empty keeps the request set
  # byte-identical on the path that already worked, so recorded cassettes replay
  # unchanged.
  # Cloudflare answers JSON only when asked for it — without the header the
  # same URL is a 400, which would have read as "no answer" and made the second
  # opinion worthless in exactly the case it exists for.
  @doh_resolvers [
    {"https://dns.google/resolve", []},
    {"https://cloudflare-dns.com/dns-query", [accept: "application/dns-json"]}
  ]

  defp doh_lookup(name, type, opts) do
    Enum.reduce_while(@doh_resolvers, {:absent, :fresh}, fn {endpoint, headers}, acc ->
      case doh_query(endpoint, headers, name, type, opts) do
        {:answers, [_ | _]} = answers -> {:halt, answers}
        # A cached negative from one resolver is worth carrying: if the other
        # is also silent, that is the answer that explains why, and it is the
        # difference between "publish it" and "wait for it".
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

  # How long a resolver has been holding this "no". The authority section of a
  # negative answer carries the zone's SOA, whose last field is the negative
  # TTL the zone publishes; the record's own TTL is what counts down in cache.
  # Below the minimum means cached, and by how much.
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
      nil -> nil
      last -> case Integer.parse(last) do
                {minimum, _} -> minimum
                :error -> nil
              end
    end
  end

  defp soa_minimum(_), do: nil

  # Injectable so a spex can drive it through its cassette plug.
  #
  # A stub written before there was a second resolver takes a url and nothing
  # else, and there is no reason for those to change: what they are standing in
  # for is "what does a public resolver say", which the headers do not affect.
  # So a one-argument stub is adapted rather than rejected.
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

  MX answers come back as `{priority, host}`; both halves are kept because the
  priority is what decides whether a receiving host is used at all, and a
  comparison that dropped it would call two different configurations equal.
  """
  @spec lookup(String.t(), atom(), keyword()) :: [String.t()]
  def lookup(name, type, opts \\ [])

  # `:inet_res` answers MX, TXT and NS from this host but returns nothing for
  # A, because address resolution goes through the system resolver rather than
  # the DNS client. Reporting that as "does not resolve" would be a false
  # negative on the most common record there is.
  def lookup(name, :a, _opts) do
    case :inet.gethostbyname(to_charlist(name)) do
      {:ok, {:hostent, _, _, _, _, addrs}} ->
        Enum.map(addrs, &(&1 |> :inet.ntoa() |> List.to_string()))

      _ ->
        []
    end
  end

  # A resolver follows a CNAME and hands back the target's records, so asking
  # for the CNAME itself often returns nothing for a name that resolves
  # perfectly well. The question a caller is asking is "is this name
  # published", so answer that.
  def lookup(name, :cname, opts) do
    case do_lookup(name, :cname, opts) do
      [] -> lookup(name, :a, opts)
      records -> records
    end
  end

  def lookup(name, type, opts), do: do_lookup(name, type, opts)

  @doc """
  Ask the zone's own nameservers rather than a recursive resolver.

  A recursive resolver caches the *absence* of a record, and a negative entry
  outlives the publish that fills it. Setup publishes a record and asks
  immediately whether it resolves, which is precisely the window where a
  cached NXDOMAIN answers for the whole TTL — reporting a record missing that
  is demonstrably there.

  Going to the authoritative servers skips every cache between here and the
  zone, which is the only way to answer "is it published *now*".

  Falls back to the recursive path when the nameservers cannot be found; a
  cached answer beats no answer.
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

  # The registrable domain's nameservers, resolved to addresses. A subdomain
  # has no NS of its own, so the zone apex is what carries them.
  defp nameserver_addresses(name, timeout) do
    case configured_nameserver() do
      nil -> discovered_nameservers(name, timeout)
      server -> [server]
    end
  end

  # `usevc: true` forces the query over TCP, and only for the fleet.
  #
  # Colima forwards a container's published ports over an SSH mux, which
  # carries TCP and not UDP — so a UDP query to the fleet's resolver times out
  # while the identical query over TCP answers at once. Against real
  # nameservers UDP is correct and cheaper, so this is not a global switch.
  defp resolver_options(servers, timeout) do
    base = [nameservers: servers, timeout: timeout]

    case configured_nameserver() do
      nil -> base
      _ -> [{:usevc, true} | base]
    end
  end

  # A nameserver to ask instead of discovering one, for the local fleet.
  #
  # Unset in production, where the zone's own NS records are the right answer
  # and asking anything else would report on a view of DNS the world does not
  # share.
  #
  # It exists because "publish a record, then check it resolves" is a real
  # round-trip that a registrar makes untestable — propagation is minutes, so
  # the suite kept a table of recorded answers instead. A table cannot be wrong
  # in the direction that matters; it can only be *absent*, and then every
  # record reads as unresolved, which is indistinguishable from a publish that
  # failed. That is precisely what happened when the table went missing.
  #
  # TCP because these are container ports on a developer's machine: colima
  # forwards published ports over an SSH mux, which carries TCP and not UDP, so
  # a UDP query to the fleet's resolver times out while the same query over TCP
  # answers immediately.
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
    # A resolver that raises is a resolver that answered nothing, which is
    # what the caller needs to know.
    error ->
      Logger.debug("[Dns] #{type} lookup for #{name} failed: #{inspect(error)}")
      []
  end

  @doc """
  The MX records published at a name, as `"priority host"` strings, sorted.

  Sorted so two readings of the same zone compare equal regardless of the
  order a resolver happened to return them in — criterion 8029 compares a
  before and an after, and an unstable order would report a change that never
  happened.
  """
  @spec mx_records(String.t(), keyword()) :: [String.t()]
  def mx_records(name, opts \\ []) do
    name |> lookup(:mx, opts) |> Enum.sort()
  end

  defp format({priority, host}) when is_integer(priority), do: "#{priority} #{to_string(host)}"

  # TXT answers arrive as a list of chunks, because a record longer than 255
  # bytes is split — and DKIM keys routinely are. Joining them is what makes
  # the value comparable to what was published.
  defp format([h | _] = chunks) when is_list(h), do: Enum.map_join(chunks, "", &List.to_string/1)

  defp format(value) when is_list(value), do: List.to_string(value)
  defp format(value) when is_binary(value), do: value

  defp format(value), do: to_string(value)
end
