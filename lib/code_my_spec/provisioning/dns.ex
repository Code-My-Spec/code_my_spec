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
    attempts = Keyword.get(opts, :attempts, 1)
    interval = Keyword.get(opts, :interval_ms, 2_000)

    Enum.reduce_while(1..attempts, false, fn attempt, _acc ->
      case doh_lookup(name, type, opts) do
        [] when attempt < attempts ->
          Process.sleep(interval)
          {:cont, false}

        [] ->
          {:halt, false}

        _answers ->
          {:halt, true}
      end
    end)
  end

  defp doh_lookup(name, type, opts) do
    url = "https://dns.google/resolve?name=#{URI.encode(name)}&type=#{type |> to_string() |> String.upcase()}"

    case req(opts).(url) do
      {:ok, %{status: 200, body: %{"Answer" => answers}}} when is_list(answers) ->
        Enum.map(answers, & &1["data"])

      _ ->
        []
    end
  end

  # Injectable so a spex can drive it through its cassette plug.
  defp req(opts) do
    Keyword.get(opts, :resolver, fn url ->
      Req.get(url, Application.get_env(:code_my_spec, __MODULE__, []))
    end)
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
        case :inet_res.resolve(to_charlist(name), :in, type,
               [nameservers: servers, timeout: timeout],
               timeout
             ) do
          {:ok, record} ->
            record |> :inet_dns.msg(:anlist) |> Enum.map(&(&1 |> :inet_dns.rr(:data) |> format()))

          _ ->
            []
        end
    end
  rescue
    _ -> lookup(name, type, opts)
  end

  # The registrable domain's nameservers, resolved to addresses. A subdomain
  # has no NS of its own, so the zone apex is what carries them.
  defp nameserver_addresses(name, timeout) do
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
