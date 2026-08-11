defmodule Mix.Tasks.Cms.ProvisioningLeaks do
  @shortdoc "List real provider resources left behind by spex recordings"

  @moduledoc """
  Show what the spex account still holds, so a bad teardown is visible rather
  than assumed away.

      MIX_ENV=test mix cms.provisioning_leaks

  Spex in the devops epic create **real** resources — Hetzner servers and
  buckets, Cloudflare records — and tear them down on the way out. Teardown is
  the only thing standing between a recording session and a bill, and it runs
  in `on_exit`, which is exactly where a crashed test is least likely to reach.
  A leak is also silent in the worst way: the next recording finds the resource
  already there and passes on residue, so the criterion whose premise is
  "this exists" stops putting it there and nobody notices until a fresh
  account fails everything at once.

  Anything prefixed `spex-` is a recording artifact and should not exist
  between runs. Everything else is real and is listed separately so the two
  are never confused — deleting the wrong one here is the expensive mistake.

  Run under `MIX_ENV=test`: it points `CodeMySpec.Repo` at `code_my_spec_dev`
  but builds against test artifacts, so it never contends for the dev compile
  lock the running `:4000` server holds. It reads dev *data*, not dev *code*.

  Read-only. It deletes nothing — what to do about a leak is a judgement call
  that depends on whether a recording is in flight.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage, Teardown}
  alias CodeMySpec.Users.Scope

  @spex_prefix "spex-"

  # How recently a server has to have been created for `--delete` to leave it
  # alone. An hour is well past any recording that is still going and well
  # short of leaving residue around to be passed on to the next run.
  @live_run_window_minutes 60

  # A DNS record is not named like a server. Hetzner resources are *prefixed*
  # `spex-`; a record made for one is `send.spex-story969-criterion8027.
  # astralbi.com` or `c8025.astralbi.com`, where the marker is a label in the
  # middle. Matching on the prefix alone reported those as real, which is the
  # answer that let a leak sit in a live zone looking like somebody's mail
  # setup.
  #
  # Anchored to a label boundary on the left so a real domain that merely
  # contains the letters is never swept in.
  #
  # The two markers terminate differently, and conflating them hid a leak.
  # `c8025` is a whole label, so it needs a boundary on both sides. `spex-` is a
  # label *prefix* — the real name is `spex-story969-criterion8027` — so
  # requiring a dot after it matched nothing, and
  # `send.spex-story969-criterion8027.astralbi.com` was reported as a real
  # record while sitting in a live zone.
  #
  # The criterion half was wrong twice over, and both ways left live resources
  # reported as real:
  #
  #   * `c80\d{2}` only ever matched criteria 8000-8099. Every other criterion
  #     — 8156, 8182, 8233 — was invisible to the sweep entirely.
  #   * It demanded the label end right after the digits, so a criterion that
  #     suffixes its host (`c8025b.astralbi.com`, one environment per letter)
  #     did not match. Two live Resend sending domains and four DNS records
  #     were sitting behind that one.
  #
  # A `c` followed by four digits at the start of a label is specific enough
  # that no real domain of ours looks like it, and the trailing `[a-z0-9]*`
  # covers whatever a criterion appends to distinguish its environments.
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

    # Servers and SSH keys took `false` here and no deleter, so `--delete`
    # silently skipped them while the report still said "re-run with --delete
    # to remove them" — an instruction for a remedy that did not exist. Two
    # leaked servers survived a `--delete` run and kept billing; the bucket in
    # the same run was removed, which is what made the gap look like success.
    #
    # Servers first: a key cannot be removed while a server still references it.
    recent = if force?, do: MapSet.new(), else: recent_server_names(%Scope{})

    report("Hetzner servers", server_names(%Scope{}), delete?, &delete_server(&1, recent))
    report("Hetzner SSH keys", ssh_key_names(%Scope{}), delete?, &delete_ssh_key/1)
    report("Hetzner buckets", bucket_names(credentials), delete?, &delete_bucket(&1, credentials))

    # Cloudflare and Resend were missing here, and they are the two that
    # matter most: a leaked bucket costs money, a leaked DNS record changes
    # where somebody's mail goes. A failed recording once left DKIM and SPF
    # records on the production zone and this task reported a clean account,
    # because it only ever looked at Hetzner.
    #
    # They need OAuth rather than an env var, which is why they were skipped.
    # The task already runs against the dev database, so the grant is right
    # there — the same row the app refreshes under a lock, with no second copy
    # to go stale.
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
  # A second, named repo pointed at dev, exactly as the spex do it when they
  # borrow a live grant. The whole application starts first — the tokens are
  # encrypted at rest, and Cloak's vault is a supervised process, so without it
  # every row comes back as an undecryptable binary rather than as "no
  # integrations found". Under `MIX_ENV=test` the endpoint is configured not to
  # serve, so nothing binds a port and the running dev server is untouched.
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

    # Sequenced rather than `&&`. `put_dynamic_repo/1` answers with the repo it
    # replaced, which is always truthy, so the conditional never decided
    # anything — it just read as though the `:ok` were contingent on it.
    case CodeMySpec.Repo.start_link(config) do
      {:ok, _} ->
        CodeMySpec.Repo.put_dynamic_repo(:leak_audit_dev_repo)
        :ok

      {:error, {:already_started, _}} ->
        CodeMySpec.Repo.put_dynamic_repo(:leak_audit_dev_repo)
        :ok

      other ->
        other
    end
  end

  defp oauth_scope do
    import Ecto.Query

    with :ok <- start_dev_repo(),
         %{id: user_id} = user <-
           CodeMySpec.Repo.one(
             from u in CodeMySpec.Users.User,
               join: i in "integrations",
               on: i.user_id == u.id,
               where: i.provider == "cloudflare",
               limit: 1
           ),
         account_id when not is_nil(account_id) <-
           CodeMySpec.Repo.one(
             from p in "user_preferences",
               where: p.user_id == ^user_id,
               select: type(p.active_account_id, :binary_id)
           ) do
      {:ok, %Scope{user: user, user_id: user_id, active_account_id: account_id}}
    else
      _ -> :error
    end
  end

  # Every record in every zone whose name carries a spex marker. Listing by
  # name rather than by zone on purpose: the failure being audited for is a
  # record landing in a zone nobody expected, so a per-zone view would file it
  # under the zone it should not have been in and read as normal.
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

  # Through the app's own teardown for the same reason `delete_bucket/2` is:
  # `Teardown.resource/3` confirms the thing is actually gone rather than
  # trusting the API's acceptance. Hetzner deletes servers asynchronously, so
  # "accepted" and "gone" are genuinely different answers here.
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

  # Names of servers young enough that a run is probably still using them.
  #
  # "Leaked" is inferred from the name, and a name cannot tell abandoned from
  # in-flight. That distinction is the whole safety property of this task and it
  # was missing: a `--delete` run removed two servers that another agent's spex
  # had provisioned minutes earlier and was still using.
  #
  # The file's own guard already said so — "a recording may be in flight, and
  # deleting somebody else's live resource is worse than refusing to start" —
  # but nothing enforced it. Age does: a recording that provisioned a server an
  # hour ago has either finished or died, and either way its teardown is not
  # coming.
  #
  # Deliberately not a lock or a harness check. Both can be stale in the
  # direction that permits deletion, and this needs to fail the other way.
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

  # Keys leak the same way servers do and are easier to miss: they cost nothing,
  # so nobody notices seven of them. They are still a credential per recording
  # sitting in the account.
  defp ssh_key_names(scope) do
    case Hetzner.list_ssh_keys(scope) do
      {:ok, keys} -> Enum.map(keys, &name_of/1)
      _ -> []
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

  @doc false
  @spec leaked?(term()) :: boolean()
  def leaked?(name) do
    name = to_string(name)
    String.starts_with?(name, @spex_prefix) or name =~ @spex_marker
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
          case deleter.(name) do
            :ok -> Mix.shell().info("    deleted #{name}")
            {:skipped, why} -> Mix.shell().info("    kept    #{name} — #{why}")
            {:error, _} -> Mix.shell().error("    FAILED  #{name}")
          end
        end

      true ->
        Mix.shell().info("  LEAKED (#{length(leaked)}): #{inspect(leaked)}")
        Mix.shell().info("  re-run with --delete to remove them")
    end
  end
end
