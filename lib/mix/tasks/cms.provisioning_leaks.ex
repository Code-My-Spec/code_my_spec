defmodule Mix.Tasks.Cms.ProvisioningLeaks do
  @shortdoc "List real provider resources left behind by spex recordings"

  @moduledoc """
  Show what the spex account still holds, so a bad teardown is visible rather
  than assumed away.

      MIX_ENV=test mix cms.provisioning_leaks

  Spex in the devops epic create **real** resources — Hetzner servers, keys,
  firewalls and buckets, Cloudflare records, Resend domains — and tear them
  down in `on_exit`, which is exactly where a crashed test is least likely to
  reach. A leak is silent: the next recording finds the resource already there
  and passes on residue.

  Anything carrying a spex marker is a recording artifact and should not exist
  between runs. Everything else is real and is listed separately so the two
  are never confused — deleting the wrong one here is the expensive mistake.

  Run under `MIX_ENV=test`: it points `CodeMySpec.Repo` at `code_my_spec_dev`
  but builds against test artifacts, so it never contends for the dev compile
  lock the running `:4000` server holds. It reads dev *data*, not dev *code*.

  Read-only by default. `--delete` removes the leaks through the app's own
  teardown, skipping servers created within the last
  `@live_run_window_minutes` (a recording may be in flight); `--force` drops
  that window.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage, Teardown}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

  @spex_prefix "spex-"

  # The drill (`test/drill/provisioning_walk.exs`) keeps a long-lived
  # environment named `spex-drill-*` between runs on purpose, so it is
  # excluded. By marker, not name: the names come from `CMS_DRILL_APP` and
  # `CMS_DRILL_DOMAIN`. Both separators, because Hetzner names use `-` and DNS
  # records sit under `spex-drill.<domain>`.
  @drill_marker ~r/(^|\.)spex-drill([-.]|$)/

  # How recently a server has to have been created for `--delete` to leave it
  # alone: well past any live recording, well short of passing residue on.
  @live_run_window_minutes 60

  # DNS records carry the marker as a label, not a prefix
  # (`send.spex-story969-criterion8027.example.com`, `c8025b.example.com`).
  # Anchored to a label boundary on the left so a real domain that merely
  # contains the letters is never swept in. `spex-` is a label *prefix*, so no
  # boundary after it; `c` + four digits starts a whole label, with
  # `[a-z0-9]*` for whatever suffix distinguishes a criterion's environments.
  # See knowledge/platform, "Provisioning leak sweep".
  @spex_marker ~r/(^|\.)(spex-|c\d{4}[a-z0-9]*(\.|$))/

  @impl Mix.Task
  def run(args) do
    delete? = "--delete" in args
    force? = "--force" in args

    Logger.configure(level: :warning)

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ex_aws)

    # The same credentials a recording uses, from the same place — reading them
    # anywhere else would audit an account the spex never touch.
    token = env!("HETZNER_API_TOKEN")

    credentials = [
      access_key_id: env!("HETZNER_S3_ACCESS_KEY_ID"),
      secret_access_key: env!("HETZNER_S3_SECRET_ACCESS_KEY"),
      region: System.get_env("HETZNER_S3_REGION", "fsn1")
    ]

    Application.put_env(:code_my_spec, CodeMySpec.Provisioning.Hetzner, api_token: token)

    # Every kind has a deleter: a report that says "re-run with --delete" must
    # mean it. Servers first: a key cannot be removed while a server still
    # references it.
    recent = if force?, do: MapSet.new(), else: recent_server_names(%Scope{})

    report("Hetzner servers", server_names(%Scope{}), delete?, &delete_server(&1, recent))
    report("Hetzner SSH keys", ssh_key_names(%Scope{}), delete?, &delete_ssh_key/1)
    report("Hetzner firewalls", firewall_names(%Scope{}), delete?, &delete_firewall/1)
    report("Hetzner buckets", bucket_names(credentials), delete?, &delete_bucket(&1, credentials))

    # Cloudflare and Resend matter most — a leaked DNS record changes where
    # somebody's mail goes. They need OAuth, taken from the dev database this
    # task already reads (the same row the app refreshes).
    case oauth_scope() do
      {:ok, scope} ->
        report("Cloudflare DNS records", dns_record_names(scope), delete?, &delete_dns(scope, &1))
        report("Resend domains", resend_domain_names(scope), delete?, &delete_domain(scope, &1))

      :error ->
        Mix.shell().info("\nCloudflare / Resend")
        Mix.shell().error("  no connected account found — these were NOT audited")
    end
  end

  # The account owner's scope, built from the dev database this task already
  # reads. Nothing is created; if there is no connected owner the caller is
  # told rather than shown an empty list, because "nothing leaked" and "nothing
  # was checked" must never look the same.
  # A second, named repo pointed at dev, as the spex do when they borrow a live
  # grant. The application starts first: tokens are encrypted at rest and
  # Cloak's vault is a supervised process. Under `MIX_ENV=test` the endpoint
  # does not serve, so the running dev server is untouched.
  defp start_dev_repo do
    {:ok, _} = Application.ensure_all_started(:code_my_spec)

    config =
      :code_my_spec
      |> Application.get_env(CodeMySpec.Repo, [])
      |> Keyword.merge(
        name: :leak_audit_dev_repo,
        database: "code_my_spec_dev",
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    # Sequenced rather than `&&`: `put_dynamic_repo/1` returns the repo it
    # replaced, which is always truthy.
    case Repo.start_link(config) do
      {:ok, _} ->
        Repo.put_dynamic_repo(:leak_audit_dev_repo)
        :ok

      {:error, {:already_started, _}} ->
        Repo.put_dynamic_repo(:leak_audit_dev_repo)
        :ok

      other ->
        other
    end
  end

  defp oauth_scope do
    import Ecto.Query

    with :ok <- start_dev_repo(),
         %{id: user_id} = user <-
           Repo.one(
             from u in CodeMySpec.Users.User,
               join: i in "integrations",
               on: i.user_id == u.id,
               where: i.provider == "cloudflare",
               limit: 1
           ),
         account_id when not is_nil(account_id) <-
           Repo.one(
             from p in "user_preferences",
               where: p.user_id == ^user_id,
               select: type(p.active_account_id, :binary_id)
           ) do
      {:ok, %Scope{user: user, user_id: user_id, active_account_id: account_id}}
    else
      _ -> :error
    end
  end

  # Every record in every zone whose name carries a spex marker, listed by name
  # rather than by zone: the failure audited for is a record in a zone nobody
  # expected.
  defp dns_record_names(scope) do
    case Cloudflare.list_zones(scope) do
      {:ok, zones} ->
        Enum.flat_map(zones, &zone_record_names(scope, &1))

      other ->
        Mix.shell().error("could not list zones: #{inspect(other)}")
        []
    end
  end

  defp zone_record_names(scope, zone) do
    case Cloudflare.list_dns_records(scope, zone["id"]) do
      {:ok, records} -> Enum.map(records, & &1["name"])
      _ -> []
    end
  end

  defp resend_domain_names(scope) do
    case Resend.list_domains(scope) do
      {:ok, domains} -> Enum.map(domains, & &1["name"])
      _ -> []
    end
  end

  defp delete_dns(scope, name) do
    with {:ok, zone} <- Cloudflare.find_zone(scope, registrable(name)),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone["id"]) do
      records
      |> Enum.filter(&(&1["name"] == name))
      |> Enum.each(&Cloudflare.delete_dns_record(scope, zone["id"], &1["id"]))

      :ok
    else
      _ -> {:error, name}
    end
  end

  defp delete_domain(scope, name) do
    with {:ok, %{"id" => id}} <- Resend.find_domain(scope, name),
         {:ok, _} <- Resend.delete_domain(scope, id) do
      :ok
    else
      _ -> {:error, name}
    end
  end

  defp registrable(name), do: name |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  # Through the app's own teardown: `Teardown.resource/3` confirms the thing is
  # gone, and Hetzner deletes servers asynchronously.
  defp delete_server(name, recent) do
    if MapSet.member?(recent, name) do
      {:skipped,
       "created in the last #{@live_run_window_minutes}m; another run may still be using " <>
         "it. Use --force once you know nothing is provisioning."}
    else
      resource = %{kind: "server", location: "hetzner/#{name}", origin: "created"}

      case Teardown.resource(%Scope{}, resource, []) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, name}
      end
    end
  end

  defp delete_ssh_key(name) do
    with {:ok, %{"id" => id}} <- Hetzner.find_ssh_key(%Scope{}, name),
         {:ok, _} <- Hetzner.delete_ssh_key(%Scope{}, id) do
      :ok
    else
      # Already gone is the outcome asked for, not a failure.
      {:error, :not_found} -> :ok
      _ -> {:error, name}
    end
  end

  # Through the app's own teardown, not a raw delete: emptying first is the
  # part people forget, and a bucket with one object in it refuses to go.
  defp delete_bucket(bucket, credentials) do
    resource = %{kind: "bucket", location: bucket, origin: "created"}

    case Teardown.resource(%Scope{}, resource, credentials: credentials) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, bucket}
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise("#{name} is not set — source envs/.env first (`set -a; source envs/.env`)")
    end
  end

  defp server_names(scope) do
    case Hetzner.list_servers(scope) do
      {:ok, servers} -> Enum.map(servers, &name_of/1)
      other -> Mix.shell().error("could not list servers: #{inspect(other)}") || []
    end
  end

  # Names of servers young enough that a run is probably still using them. A
  # name cannot tell abandoned from in-flight, so age does: an hour-old
  # recording has finished or died. Deliberately not a lock or a harness check,
  # which can be stale in the direction that permits deletion.
  defp recent_server_names(scope) do
    case Hetzner.list_servers(scope) do
      {:ok, servers} ->
        cutoff = DateTime.add(DateTime.utc_now(), -@live_run_window_minutes * 60, :second)

        servers
        |> Enum.filter(&created_after?(&1, cutoff))
        |> Enum.map(&name_of/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # No timestamp means no evidence it is old, and the safe reading of "unknown"
  # here is "recent".
  defp created_after?(server, cutoff) do
    case DateTime.from_iso8601(to_string(server["created"] || "")) do
      {:ok, created, _} -> DateTime.compare(created, cutoff) == :gt
      _ -> true
    end
  end

  # Keys cost nothing, so leaks go unnoticed; each is still a credential.
  defp ssh_key_names(scope) do
    case Hetzner.list_ssh_keys(scope) do
      {:ok, keys} -> Enum.map(keys, &name_of/1)
      other -> Mix.shell().error("could not list SSH keys: #{inspect(other)}") || []
    end
  end

  # Only firewalls applied to nothing: one attached to a server belongs to an
  # unfinished run, protected by the server sweep's recency window. A failed
  # list call says so rather than returning `[]` — "nothing leaked" and
  # "nothing was checked" must never look the same.
  defp firewall_names(scope) do
    case Hetzner.list_firewalls(scope) do
      {:ok, firewalls} -> firewalls |> Enum.filter(&unattached?/1) |> Enum.map(&name_of/1)
      other -> Mix.shell().error("could not list firewalls: #{inspect(other)}") || []
    end
  end

  defp unattached?(firewall) do
    MapAccess.get(firewall, :applied_to, []) == []
  end

  defp delete_firewall(name) do
    with {:ok, %{"id" => id}} <- Hetzner.find_firewall(%Scope{}, name),
         {:ok, _} <- Hetzner.delete_firewall(%Scope{}, id) do
      :ok
    else
      _ -> {:error, name}
    end
  end

  defp bucket_names(credentials) do
    case Storage.list_buckets(credentials, []) do
      {:ok, buckets} ->
        Enum.map(buckets, &name_of/1)

      other ->
        Mix.shell().error("could not list buckets: #{inspect(other)}")
        []
    end
  end

  # Resources that belong to the suite rather than to a run, never swept.
  # Empty today (inbound mail moved to fake providers); kept for the next one.
  @kept []

  # A build server is named after the commit it builds (`builder-<sha>`), never
  # after the project, so the marker cannot see one. Every path in `Builder`
  # destroys the server it made, so one still here is leaked; `--delete`
  # still refuses anything inside `@live_run_window_minutes`.
  @builder_prefix "builder-"

  @doc false
  @spec leaked?(term()) :: boolean()
  def leaked?(name) do
    name = to_string(name)

    cond do
      Enum.any?(@kept, &(name == &1 or String.ends_with?(name, "." <> &1))) -> false
      name =~ @drill_marker -> false
      String.starts_with?(name, @spex_prefix) -> true
      String.starts_with?(name, @builder_prefix) -> true
      true -> name =~ @spex_marker
    end
  end

  # Providers are inconsistent about this: servers come back as maps with
  # string keys, buckets sometimes as bare names.
  defp name_of(%{name: name}), do: name
  defp name_of(%{"name" => name}), do: name
  defp name_of(name) when is_binary(name), do: name
  defp name_of(other), do: inspect(other)

  # The two lists never merge: a leak is deleted and a real resource is not,
  # and the whole value of this task is that the distinction is obvious at a
  # glance rather than inferred from a name.
  defp report(label, names, delete?, deleter) do
    {leaked, real} = Enum.split_with(names, &leaked?/1)

    Mix.shell().info("\n#{label}")
    Mix.shell().info("  real (#{length(real)}): #{inspect(real)}")

    cond do
      leaked == [] ->
        Mix.shell().info("  leaked: none")

      delete? and deleter ->
        Mix.shell().info("  LEAKED (#{length(leaked)}): deleting…")

        for name <- leaked do
          delete_leak(deleter, name)
        end

      true ->
        Mix.shell().info("  LEAKED (#{length(leaked)}): #{inspect(leaked)}")
        Mix.shell().info("  re-run with --delete to remove them")
    end
  end

  defp delete_leak(deleter, name) do
    case deleter.(name) do
      :ok -> Mix.shell().info("    deleted #{name}")
      {:skipped, why} -> Mix.shell().info("    kept    #{name} — #{why}")
      {:error, _} -> Mix.shell().error("    FAILED  #{name}")
    end
  end
end
