defmodule CodeMySpec.Resources.Inventory do
  @moduledoc """
  Everything each provider says the account holds, enumerated once.

  ## Why enumerate rather than verify

  `Provisioning.verify/3` asks "is this particular thing still there", one step
  at a time. Across eleven projects and fifteen steps that is a hundred and
  sixty-five calls, and it can still only ever confirm or deny things we
  already wrote down.

  A resource nobody recorded is invisible to that. `mix cms.provisioning_leaks`
  exists precisely because they occur — a crashed teardown leaves things
  behind, and the next run finds them already there and reports success on the
  residue. Six list calls find those, and are faster than the one-at-a-time
  version they replace.

  ## Why each provider is asked independently

  A failure is confined to its own key. One provider being unreachable must not
  decide what the page can say about the other three — that is the
  "failure to ask, rendered as an answer" this epic keeps finding, and the
  account-level view is where it would do the most damage.
  """

  require Logger

  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage}
  alias CodeMySpec.Users.Scope

  @type resource :: %{kind: String.t(), location: String.t(), identifier: String.t() | nil}
  @type answer :: {:ok, [resource()]} | {:error, term()}

  @doc """
  Ask every provider what it holds.

  Returns a map of provider to `{:ok, resources}` or `{:error, reason}`. Never
  a bare list: the caller has to be able to tell "asked, and there is nothing"
  from "could not ask", and collapsing those is the whole failure this guards.
  """
  @spec list(Scope.t()) :: %{atom() => answer()}
  def list(%Scope{} = scope) do
    case config(:list) do
      nil -> read(scope)
      fun -> fun.(scope)
    end
  end

  defp read(scope) do
    # Sequential rather than concurrent on purpose. Four providers is a couple
    # of seconds, the page reads them off the mount anyway, and a task per
    # provider would need the scope copied into each — the kind of thing that
    # is cheap to add later and awkward to unpick if it was never needed.
    %{
      hetzner: hetzner(scope),
      cloudflare: cloudflare(scope),
      resend: resend(scope),
      storage: storage(scope)
    }
  end

  defp hetzner(scope) do
    with {:ok, servers} <- Hetzner.list_servers(scope),
         {:ok, firewalls} <- Hetzner.list_firewalls(scope),
         {:ok, keys} <- Hetzner.list_ssh_keys(scope) do
      {:ok,
       Enum.map(servers, &server_resource/1) ++
         Enum.map(firewalls, &named("firewall", "hetzner", &1)) ++
         Enum.map(keys, &ssh_key_resource/1)}
    end
  end

  defp server_resource(server) do
    %{
      kind: "server",
      location: "hetzner/#{server["name"]}",
      identifier: get_in(server, ["public_net", "ipv4", "ip"])
    }
  end

  defp ssh_key_resource(key) do
    %{kind: "ssh_key", location: "hetzner/#{key["name"]}", identifier: key["fingerprint"]}
  end

  defp named(kind, provider, %{"name" => name}), do: %{kind: kind, location: "#{provider}/#{name}", identifier: nil}
  defp named(kind, provider, name) when is_binary(name), do: %{kind: kind, location: "#{provider}/#{name}", identifier: nil}

  # Records, not just zones. A zone is one line and never the thing that is
  # wrong; the record pointing at a released address is.
  defp cloudflare(scope) do
    with {:ok, zones} <- Cloudflare.list_zones(scope) do
      Enum.reduce_while(zones, {:ok, []}, fn zone, {:ok, acc} ->
        case Cloudflare.list_dns_records(scope, zone["id"]) do
          {:ok, records} -> {:cont, {:ok, acc ++ Enum.map(records, &dns_resource/1)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp dns_resource(record) do
    %{
      kind: "dns_record",
      location: record["name"],
      identifier: "#{record["type"]} #{record["content"]}"
    }
  end

  defp resend(scope) do
    with {:ok, domains} <- Resend.list_domains(scope),
         {:ok, webhooks} <- Resend.list_webhooks(scope) do
      {:ok,
       Enum.map(domains, &%{kind: "sending_domain", location: "resend/#{&1["name"]}", identifier: &1["status"]}) ++
         Enum.map(webhooks, &%{kind: "webhook", location: &1["endpoint"], identifier: &1["status"]})}
    end
  end

  # Object storage keys are console-only at Hetzner, so an account that never
  # set storage up has none. That is "nothing to ask with" rather than a
  # failure, and reporting it as an error would put a red mark on a provider
  # the account does not use.
  defp storage(scope) do
    case Storage.credentials(scope) do
      {:ok, credentials} ->
        with {:ok, buckets} <- Storage.list_buckets(credentials) do
          {:ok, Enum.map(buckets, &named("bucket", "storage", &1))}
        end

      :none ->
        {:ok, []}
    end
  end

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]
end
