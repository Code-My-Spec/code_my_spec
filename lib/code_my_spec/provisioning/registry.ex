defmodule CodeMySpec.Provisioning.Registry do
  @moduledoc """
  Where built images live, and how they stop costing money.

  A `distribution` container (`cms-registry`) on the box the app runs on,
  one per box: projects sharing a box share the process, the way `Database`
  does. Isolation between projects is the repository path
  (`repository/2`) and each project's own htpasswd entry.

  - **Address.** `localhost:5000` by default; the deploy steps bind it to the
    app box's private-network IP and pass `:registry_host` `<ip>:5000`, a
    reference valid for the builder (push) and the app box (pull). Never on
    a public interface.
  - **Storage.** `:filesystem` (a volume on the box) is the design;
    retention is `prune/2`. `:s3` remains behind `storage: :s3` but is not
    used: Hetzner's eventually consistent storage breaks pushes.
  - Serving the registry protocol is `distribution`'s job, not ours.

  See knowledge/provisioning, "Registry".
  """

  require Logger

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.HostBaseline
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  # Long enough to roll back, short enough that a weekly cadence does not
  # keep a year of images. Overridable.
  @default_retention_days 30

  # Retention applies to blobs: they hold the space, and a manifest pointing
  # at expired blobs is already unusable.
  @blobs_prefix "docker/registry/v2/blobs/"

  @doc """
  Make sure the registry's bucket exists and forgets old images on its own.

  Idempotent: an existing registry bucket is the ordinary case.
  """
  @spec ensure(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%Scope{} = scope, opts \\ []) do
    ensure_storage(Keyword.get(opts, :storage, :filesystem), scope, opts)
  end

  # Nothing to provision: blobs live in a volume on the box. `:none` rather
  # than a name, so no caller records a bucket that was never made.
  defp ensure_storage(:filesystem, _scope, _opts), do: {:ok, :none}

  defp ensure_storage(:s3, scope, opts) do
    with {:ok, credentials} <- credentials(scope, opts),
         bucket <- bucket_name(scope, opts),
         {:ok, _} <- Storage.ensure_bucket(bucket, credentials, opts),
         :ok <- put_retention(bucket, credentials, opts) do
      {:ok, bucket}
    end
  end

  @doc """
  The address a deploy pulls an image from.

  Built rather than reported back by the builder: the deploy has to know where
  to look before anything has been pushed.
  """
  @spec reference(Scope.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reference(%Scope{} = scope, tag, opts \\ []) when is_binary(tag) do
    with {:ok, image} <- image(scope, opts) do
      {:ok, "#{image}:#{tag}"}
    end
  end

  @doc """
  The bare path a tag is appended to, with no tag of its own.

  A generated kamal config's `image:` field is the bare repository path
  (`repository/2`) — kamal reads the host from `registry.server`. This is the
  host-qualified form. Projects never collide because each has its own
  repository path; there is no owner segment.
  """
  @spec image(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def image(%Scope{} = scope, opts \\ []) do
    with {:ok, host} <- host(opts),
         {:ok, repository} <- repository(scope, opts) do
      {:ok, "#{host}/#{repository}"}
    end
  end

  @doc "How long images are kept, in days."
  @spec retention_days(keyword()) :: pos_integer()
  def retention_days(opts), do: Keyword.get(opts, :retention_days, @default_retention_days)

  @doc """
  Whether a bucket lifecycle rule actually exists to enforce retention.

  `retention_days/1` is a duration regardless of storage mode. Only `:s3`
  installs a bucket lifecycle rule; under `:filesystem` it is `prune/2` that
  enforces retention. A caller that records or renders retention must ask
  this, or it claims a window is enforced when nothing is behind it.
  """
  @spec retention_enforced?(keyword()) :: boolean()
  def retention_enforced?(opts), do: Keyword.get(opts, :storage, :filesystem) == :s3

  # Enough to roll back a bad deploy or two. Overridable per project.
  @default_keep_images 5

  @doc "How many images stay on the box before `prune/2` deletes the rest."
  @spec keep_images(keyword()) :: pos_integer()
  def keep_images(opts), do: Keyword.get(opts, :keep_images, @default_keep_images)

  @doc "The prefix retention applies to."
  @spec blobs_prefix() :: String.t()
  def blobs_prefix, do: @blobs_prefix

  defp put_retention(bucket, credentials, opts) do
    Storage.put_lifecycle(
      bucket,
      retention_days(opts),
      credentials,
      Keyword.put(opts, :prefix, @blobs_prefix)
    )
  end

  defp credentials(scope, opts) do
    case Keyword.get(opts, :credentials) || Storage.credentials(scope, opts) do
      :none -> {:error, :no_storage_credentials}
      {:ok, credentials} -> {:ok, credentials}
      credentials when is_list(credentials) -> {:ok, credentials}
    end
  end

  # Its own bucket, never a prefix in the app's: two retention rules in one
  # bucket and the second written wins. Per environment, because environments
  # may run different architectures (an image cannot be promoted across them),
  # and two `distribution` instances cannot share a bucket. Public so whose
  # bucket holds the images is assertable.
  @doc "The bucket this project's images are stored in."
  @spec bucket_name(Scope.t(), keyword()) :: String.t()
  def bucket_name(%Scope{} = scope, opts \\ []) do
    Keyword.get(opts, :bucket) || configured_bucket() ||
      derived_bucket_name(scope, Keyword.get(opts, :environment))
  end

  defp derived_bucket_name(scope, environment) do
    case project_slug(scope) do
      slug when is_binary(slug) and slug != "" ->
        suffix = if environment in [nil, ""], do: "", else: "-#{environment}"
        "#{slug}-registry#{suffix}"

      _ ->
        # As `Storage.bucket_name/2`: bucket names are unique per account, so a
        # generic fallback would be shared by every unnamed project.
        raise ArgumentError, "cannot derive a registry bucket name: the project has no name"
    end
  end

  defp configured_bucket,
    do: Application.get_env(:code_my_spec, __MODULE__, [])[:bucket]

  @doc """
  This project's own path within the registry, with no host and no tag.

  What `image/2` appends a host onto, and what a kamal config's `image:`
  field names verbatim: kamal wants it bare and reads the host from
  `registry.server` (a host-qualified `image:` silently duplicates it).
  """
  @spec repository(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def repository(%Scope{} = scope, opts \\ []) do
    case Keyword.get(opts, :repository) || project_slug(scope) do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _ -> {:error, :no_project}
    end
  end

  # Loopback by default; the steps pass the private-network address as
  # `:registry_host`. An image reference is baked in, so push and pull must
  # use the identical string. `:registry_host`, not `:host`: in the deploy
  # step's opts `:host` is the app's own hostname.
  @default_host "localhost:5000"

  defp host(opts) do
    case Keyword.get(opts, :registry_host) || configured_host() || @default_host do
      host when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, :no_registry_host}
    end
  end

  defp configured_host,
    do: Application.get_env(:code_my_spec, __MODULE__, [])[:host]

  @doc """
  The port the registry listens on, on loopback.

  Public because the builder, the container's port mapping and the
  reference must agree.
  """
  @spec port() :: pos_integer()
  def port, do: 5000

  @doc "The address a deploy pulls from, and a build pushes to."
  @spec default_host() :: String.t()
  def default_host, do: @default_host

  @container "cms-registry"
  @volume "cms-registry-data"
  @username_prefix "cms"
  @password_secret "registry_password"

  @doc """
  The credential this project's registry answers to.

  The username is `cms_<project>`: one htpasswd file on a shared box holds an
  entry per project.

  Minted once into `ProjectSecrets`. kamal refuses to render a config without
  a registry password and performs a `docker login`, so the registry has real
  credentials. Private-network-only reachability is a property of the
  firewall, not the registry, so the credential is real anyway.
  """
  @spec credential(Scope.t()) ::
          {:ok, %{username: String.t(), password: String.t()}} | {:error, term()}
  def credential(%Scope{} = scope) do
    with {:ok, username} <- tenant_username(scope) do
      case ProjectSecrets.fetch_value(scope, @password_secret) do
        {:ok, password} when is_binary(password) and password != "" ->
          {:ok, %{username: username, password: password}}

        _ ->
          password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

          with {:ok, _} <- ProjectSecrets.put_value(scope, @password_secret, password) do
            {:ok, %{username: username, password: password}}
          end
      end
    end
  end

  defp tenant_username(scope) do
    case project_slug(scope) do
      slug when is_binary(slug) and slug != "" ->
        {:ok, "#{@username_prefix}_#{String.replace(slug, "-", "_")}"}

      _ ->
        {:error, :no_project}
    end
  end

  @doc """
  Start the box-wide registry container, account-side.

  The `distribution` container itself, backed by whichever bucket the first
  project to reach this box supplied. Idempotent: a running container is left
  alone rather than restarted under another project's pulls.

  `:run` takes the command and returns `{output, status}`, which is what
  makes the command assertable without a box.
  """
  @spec ensure_container(Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_container(%Scope{} = scope, opts \\ []) do
    run = Keyword.fetch!(opts, :run)
    bind = Keyword.get(opts, :bind, "127.0.0.1")
    location = Keyword.get(opts, :location, "fsn1")
    bucket = bucket_name(scope, opts)

    if container_running?(run) do
      {:ok, %{bucket: bucket, bind: running_bind(run, bind), port: port()}}
    else
      with {:ok, credentials} <- credentials(scope, opts) do
        command = create_container_command(bucket, credentials, bind, location, opts)

        case run.([command]) do
          {_output, 0} -> {:ok, %{bucket: bucket, bind: bind, port: port()}}
          {output, status} -> {:error, {:registry_start_failed, status, String.trim(output)}}
        end
      end
    end
  end

  @doc """
  Give this project its own credential on an already-running registry.

  Never starts the container: refuses with `:registry_not_provisioned` if it
  is not up.

  Idempotent: this project's htpasswd entry is upserted — the container may
  already hold other projects' entries. Also trusts the registry on this
  box's Docker daemon (the box pulls from it) and waits for `/v2/` to answer.

  `:bind` is the address it listens on, loopback by default; corrected to
  what the running container is actually published on.

  `:run` takes the command and returns `{output, status}`, which is what makes
  the command assertable without a box.
  """
  @spec serve(Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def serve(%Scope{} = scope, opts \\ []) do
    run = Keyword.fetch!(opts, :run)
    bind = Keyword.get(opts, :bind, "127.0.0.1")

    with true <- container_running?(run) || {:error, :registry_not_provisioned},
         bind = running_bind(run, bind),
         {:ok, credential} <- serve_credential(scope, opts),
         :ok <- ensure_htpasswd(run, credential, opts) do
      bucket = bucket_name(scope, opts)

      # This box pulls from the registry it hosts, so it needs the same
      # plain-HTTP trust the builder does.
      run.([trust_command("#{bind}:#{port()}")])

      await_registry(run, bucket, bind, credential, Keyword.get(opts, :registry_attempts, 15))
    end
  end

  # The bind the running container is actually published on (`docker port`),
  # rather than the caller's guess: a box carrying several private networks
  # makes the guess ambiguous. Falls back to the caller's value when the
  # output cannot be parsed.
  defp running_bind(run, fallback) do
    case run.(["docker port #{@container} #{port()}/tcp 2>&1"]) do
      {output, 0} ->
        case Regex.run(~r/(\S+):#{port()}\s*$/, String.trim(output)) do
          [_, address] -> address
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  # Counts only container-id lines, so an ssh banner on the same stream cannot
  # read as "running".
  defp container_running?(run) do
    case run.(["docker ps -q -f name=^/#{@container}$"]) do
      {output, 0} -> output |> container_ids() |> Enum.any?()
      _ -> false
    end
  end

  defp container_ids(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{12,64}$/))
  end

  # Replaces only this project's line. `|| true`: `grep -v` exits 1 when
  # nothing survives, which is just an empty start.
  #
  # `cat tmp > path`, never `mv`: the container bind-mounts the file's inode,
  # and a rename leaves a running container reading the orphaned original.
  defp ensure_htpasswd(run, credential, opts) do
    auth_dir = Keyword.get(opts, :auth_dir, "/etc/cms-registry")
    path = "#{auth_dir}/htpasswd"
    entry = "#{credential.username}:#{Bcrypt.hash_pwd_salt(credential.password)}"

    command =
      "mkdir -p #{auth_dir} && touch #{path} && " <>
        "(grep -v #{shell_escape("^#{credential.username}:")} #{path} > #{path}.tmp || true) && " <>
        "printf '%s\\n' #{shell_escape(entry)} >> #{path}.tmp && " <>
        "cat #{path}.tmp > #{path} && rm -f #{path}.tmp && chmod 600 #{path}"

    case run.([command]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:registry_credential_not_set, status, String.trim(output)}}
    end
  end

  # `docker run -d` returning 0 means created, not up. Asks the registry
  # itself, and on failure returns the container's logs, where the reason is.
  defp await_registry(run, bucket, bind, credential, attempts) do
    case probe(run, bind, credential) do
      :ok ->
        {:ok, %{bucket: bucket, bind: bind, port: port()}}

      :error when attempts > 1 ->
        Wait.sleep(2_000)
        await_registry(run, bucket, bind, credential, attempts - 1)

      :error ->
        {logs, _} = run.(["docker logs --tail 50 #{@container} 2>&1"])
        {:error, {:registry_not_listening, "#{bind}:#{port()}", String.trim(logs)}}
    end
  end

  # The one check `await_registry/5` and `reachable?/2` share: does `/v2/`
  # answer through this project's credential.
  defp probe(run, bind, credential) do
    auth = "#{credential.username}:#{credential.password}"

    case run.(["curl -sf -u #{shell_escape(auth)} http://#{bind}:#{port()}/v2/ > /dev/null"]) do
      {_output, 0} -> :ok
      _ -> :error
    end
  end

  @doc """
  Whether the registry actually answers on a box, right now.

  `verify(:server, …)` uses this so a box that exists with a leftover
  `DATABASE_URL` does not count as serving a registry. One probe, not the
  start-up loop.

  `:run` is required; `:bind` defaults to loopback, corrected against the
  running container.
  """
  @spec reachable?(Scope.t(), keyword()) :: boolean()
  def reachable?(%Scope{} = scope, opts) do
    run = Keyword.fetch!(opts, :run)
    bind = running_bind(run, Keyword.get(opts, :bind, "127.0.0.1"))

    case serve_credential(scope, opts) do
      {:ok, credential} -> probe(run, bind, credential) == :ok
      _ -> false
    end
  end

  # Injectable so a test about the registry need not mint a project
  # secret.
  defp serve_credential(scope, opts) do
    case Keyword.get(opts, :registry_credentials) do
      %{username: _, password: _} = credential -> {:ok, credential}
      _ -> credential(scope)
    end
  end

  @doc """
  Keep only the `keep_images/1` most recent images, deleting the rest and
  reclaiming the blobs only they held.

  `:filesystem` storage has no bucket lifecycle rule, so this is retention.
  Tags are never reused, so the mtime of a tag's `current/link` is when it
  was pushed. Newest first, keep `keep_images/1`, delete older tags by the
  manifest digest their link names, then run the registry's garbage-collect
  once (shared layers kept images reference survive).

  A repository with nothing pushed yet has nothing to prune. Best-effort: the
  caller logs an `{:error, _}`; a deploy that shipped must not fail on its
  cleanup.
  """
  @spec prune(Scope.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def prune(%Scope{} = scope, opts \\ []) do
    run = Keyword.fetch!(opts, :run)
    bind = Keyword.get(opts, :bind, "127.0.0.1")
    keep = keep_images(opts)

    with {:ok, repository} <- repository(scope, opts),
         {:ok, credential} <- serve_credential(scope, opts),
         {:ok, tags} <- tags_by_recency(repository, run) do
      to_prune = Enum.drop(tags, keep)

      deleted =
        Enum.filter(to_prune, fn tag ->
          delete_tag(repository, tag, bind, credential, run) == :ok
        end)

      case deleted do
        [] -> {:ok, []}
        _ -> with :ok <- garbage_collect(run), do: {:ok, deleted}
      end
    end
  end

  defp tags_dir(repository),
    do: "/var/lib/registry/docker/registry/v2/repositories/#{repository}/_manifests/tags"

  # One shell invocation inside the container. `[ -d ... ] || exit 0`: a
  # project with no images has no directory, which is nothing to prune.
  defp tags_by_recency(repository, run) do
    dir = tags_dir(repository)

    script =
      "[ -d #{shell_escape(dir)} ] || exit 0; " <>
        "for d in #{shell_escape(dir)}/*/; do " <>
        ~s{t=$(stat -c %Y "$d"current/link 2>/dev/null) && echo "$t $(basename "$d")"; } <>
        "done"

    case run.(["docker exec #{@container} sh -c #{shell_escape(script)}"]) do
      {output, 0} -> {:ok, parse_tag_listing(output)}
      {output, status} -> {:error, {:prune_listing_failed, status, String.trim(output)}}
    end
  end

  # Newest first; tags are commit SHAs, so recency is the mtime. Lines that are
  # not `<int> <tag>` (a banner, a stray log line) are skipped, not fatal.
  defp parse_tag_listing(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, " ", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.flat_map(fn [ts, tag] ->
      case Integer.parse(ts) do
        {int, ""} -> [{int, tag}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {ts, _tag} -> ts end, :desc)
    |> Enum.map(fn {_ts, tag} -> tag end)
  end

  # The digest comes from the tag's link file. Best-effort per tag, but only
  # a 202 counts as deleted — `distribution` answers 405 when deletes are
  # disabled, which must not read as pruned.
  defp delete_tag(repository, tag, bind, credential, run) do
    dir = tags_dir(repository)
    auth = "#{credential.username}:#{credential.password}"

    with {digest, 0} <- run.(["docker exec #{@container} cat #{dir}/#{tag}/current/link"]),
         digest = String.trim(digest),
         true <- digest != "",
         {status, 0} <-
           run.([
             "curl -s -o /dev/null -w '%{http_code}' -u #{shell_escape(auth)} -X DELETE " <>
               "http://#{bind}:#{port()}/v2/#{repository}/manifests/#{digest}"
           ]),
         "202" <- String.trim(status) do
      :ok
    else
      other ->
        Logger.warning("[Registry] delete of #{repository}:#{tag} failed: #{inspect(other)}")
        {:error, {:delete_failed, tag}}
    end
  end

  # Deleting a manifest leaves its layers until this runs. No `-m`: that also
  # sweeps untagged manifests, which is not "keep the last N".
  defp garbage_collect(run) do
    case run.([
           "docker exec #{@container} /bin/registry garbage-collect /etc/distribution/config.yml"
         ]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:prune_gc_failed, status, String.trim(output)}}
    end
  end

  # `--restart always`: the registry must survive a reboot, or a rollback
  # cannot pull. Only built for a container `ensure_container/2` found not
  # running; the htpasswd it mounts is kept current by `ensure_htpasswd/3`.
  defp create_container_command(bucket, credentials, bind, location, opts) do
    image = Keyword.get(opts, :registry_image, "registry:3")

    env =
      opts
      |> Keyword.get(:storage, :filesystem)
      |> storage_env(bucket, credentials, location)
      |> Enum.map_join(" ", fn {name, value} -> "-e #{name}=#{shell_escape(value)}" end)

    # `:auth_dir` is overridable for `local_runner` on Colima, where the bind
    # mount resolves inside a VM that cannot see the host's `/etc`.
    auth_dir = Keyword.get(opts, :auth_dir, "/etc/cms-registry")

    # `REGISTRY_STORAGE_DELETE_ENABLED=true`, or manifest DELETE answers 405
    # and `prune/2` deletes nothing.
    "docker rm -f #{@container} >/dev/null 2>&1; " <>
      "docker run -d --name #{@container} --restart always " <>
      "-v #{auth_dir}/htpasswd:/auth/htpasswd:ro " <>
      "-v #{@volume}:/var/lib/registry " <>
      "-e REGISTRY_AUTH=htpasswd " <>
      "-e REGISTRY_AUTH_HTPASSWD_REALM=cms " <>
      "-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd " <>
      "-e REGISTRY_STORAGE_DELETE_ENABLED=true " <>
      "-p #{bind}:#{port()}:#{port()} #{env} #{image}"
  end

  @doc """
  Tell a box's Docker daemon this registry speaks plain HTTP.

  Docker assumes HTTPS for every registry except `localhost`; against a
  plain-HTTP registry the push fails with a timeout. Both ends need it: the
  builder to push, the app's box to pull. No TLS because the registry is only
  on the private network.

  Docker is restarted only when the file changes, since a restart stops the
  app.
  """
  @spec trust_command(String.t()) :: String.t()
  def trust_command(host) do
    HostBaseline.docker_command(host)
  end

  # Which store is configuration: `:s3` stays reachable (path-style addressing
  # for Hetzner) for whoever revisits it; `:filesystem` is the default.
  defp storage_env(:s3, bucket, credentials, location) do
    [
      {"REGISTRY_STORAGE", "s3"},
      {"REGISTRY_STORAGE_S3_REGION", location},
      {"REGISTRY_STORAGE_S3_REGIONENDPOINT", "https://#{location}.your-objectstorage.com"},
      {"REGISTRY_STORAGE_S3_FORCEPATHSTYLE", "true"},
      {"REGISTRY_STORAGE_S3_BUCKET", bucket},
      {"REGISTRY_STORAGE_S3_ACCESSKEY", Keyword.fetch!(credentials, :access_key_id)},
      {"REGISTRY_STORAGE_S3_SECRETKEY", Keyword.fetch!(credentials, :secret_access_key)},
      # Answers a push's read-after-write from memory instead of the
      # eventually consistent bucket.
      {"REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR", "inmemory"}
    ]
  end

  # The default and the design: with Hetzner's bucket, pushes failed
  # `unknown blob` even with the descriptor cache. A volume gives up the
  # registry surviving the box; images are rebuildable. Retention is
  # `prune/2`.
  defp storage_env(:filesystem, _bucket, _credentials, _location) do
    [
      {"REGISTRY_STORAGE", "filesystem"},
      {"REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY", "/var/lib/registry"}
    ]
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp project_slug(%Scope{active_project: %{name: name}}) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp project_slug(_scope), do: nil
end
