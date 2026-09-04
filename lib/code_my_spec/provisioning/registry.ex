defmodule CodeMySpec.Provisioning.Registry do
  @moduledoc """
  Where built images live, and how they stop costing money.

  On the box the app already runs on, backed by the customer's own bucket —
  and, since an account can put more than one project on the same box, a
  singleton there rather than one container per project.

  This was one shared registry of ours first, on the reasoning that story 992
  is called *my images are built on infrastructure I never maintain*, so a
  bucket Sam pays for holding a registry Sam's lifecycle rule prunes would be
  infrastructure Sam maintains. That argument does not survive contact with
  what we already install on his box: setup puts Docker, kamal-proxy, a
  firewall and TLS there and he touches none of it, and a registry container
  is the same kind of thing.

  It then went per-customer, per-box: a shared registry meant one store
  holding every customer's application images, which is a cross-tenant
  boundary, and isolation was the acceptance criterion for the multi-tenant
  work — a bug in one registry's auth would leak every customer's proprietary
  code as a pullable image. That held exactly as long as "per customer" and
  "per box" were the same fact. They no longer are: an account can put a
  second project on a box it already has one on, and per-customer isolation
  inside a shared box means per-project data on that box, not per-project
  processes — the same shape `Database` settled on. What actually isolates
  one project's images from another's here is the repository path within the
  registry (`bucket_name/2`, `repository/2`) and each project's own htpasswd
  entry, not a second registry nobody asked this box to run twice.

  8240 wants a deploy that pulls without a GitHub credential: it pulls from
  `localhost`, so there is no credential at all. 8241 wants old images to
  expire without anyone remembering: retention is still the bucket lifecycle
  rule we have already written and debugged against Hetzner's Ceph, which is
  the part of running a registry that actually bites — they fill disks
  silently, because every image ever built stays until something deletes it.

  ## Why the address is `localhost`

  The registry binds to loopback on the app's own box and is never exposed.
  The deploy pulls `localhost:5000/<repo>:<tag>` from the machine the registry
  is on, and the builder pushes that same string through an SSH tunnel to the
  same port. One reference, valid at both ends, and nothing listening on a
  public interface: no certificate, no basic-auth secret, no DNS record, and
  no registry endpoint for anyone to find.

  This owns the bucket, the retention and the address. Serving the registry
  protocol is `distribution`'s job, not ours.
  """

  require Logger

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  # Long enough to roll back to something that worked, short enough that a
  # weekly deploy cadence does not accumulate a year of images. Overridable,
  # because a project that deploys hourly wants a different answer.
  @default_retention_days 30

  # A registry keeps blobs and manifests apart. Retention applies to blobs:
  # they are what the space goes on, and a manifest pointing at expired blobs
  # is already unusable.
  @blobs_prefix "docker/registry/v2/blobs/"

  @doc """
  Make sure the registry's bucket exists and forgets old images on its own.

  Idempotent: setup runs more than once, and a registry that already exists is
  the ordinary case rather than a problem.
  """
  @spec ensure(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%Scope{} = scope, opts \\ []) do
    ensure_storage(Keyword.get(opts, :storage, :filesystem), scope, opts)
  end

  # Nothing to provision: the registry keeps its blobs in a volume on the box.
  # Returns `:none` rather than the name, so a caller cannot record a bucket
  # resource for a bucket that was never made — teardown would then report
  # deleting something that does not exist, which is the same lie in the other
  # direction.
  #
  # The name is still meaningful and still used, as the label that tells one
  # project's registry from another's.
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
  to look before anything has been pushed, and a reference the builder invents
  is one more thing that can disagree with where it actually went.
  """
  @spec reference(Scope.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reference(%Scope{} = scope, tag, opts \\ []) when is_binary(tag) do
    with {:ok, image} <- image(scope, opts) do
      {:ok, "#{image}:#{tag}"}
    end
  end

  @doc """
  The bare path a tag is appended to, with no tag of its own.

  What a generated kamal config's `image:` field names — a bare repository
  path, exactly like `reference/3` builds on, minus the tag a specific build
  carries. A generator composing that field from `owner`/`app` opts the way
  ghcr.io wants them named this project's real repository path only by
  coincidence, since this registry has no owner segment at all: two projects
  never collide here because each gets its own repository path, not because
  of anything an org name would add.
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

  `retention_days/1` answers with a number regardless of storage mode — it is
  a duration, not a claim about who applies it. Only `ensure_storage(:s3, ...)`
  ever calls `Storage.put_lifecycle/4`; `:filesystem` — local-volume storage,
  the real and final design (1b4af45c) rather than a placeholder waiting on an
  S3 fix — creates no bucket and installs no rule, so a bucket lifecycle rule
  is never what enforces retention there. `prune/2` is.

  A caller that records or renders retention has to ask this, not just read
  `retention_days/1`, or it claims a window is enforced when nothing is
  behind it — the 8241 bug this exists to prevent from coming back.
  """
  @spec retention_enforced?(keyword()) :: boolean()
  def retention_enforced?(opts), do: Keyword.get(opts, :storage, :filesystem) == :s3

  # Keeps enough images to roll back a bad deploy or two while it is still
  # fresh in mind, without turning every push into a bigger volume than the
  # last. Overridable, like `retention_days`, because how far back "roll
  # back" needs to reach is a project's call, not ours.
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

  # The project's own bucket, in the project's own account — the registry is
  # the customer's now, so its storage is too.
  #
  # Still its own bucket rather than a prefix inside the app's: a registry's
  # layout is the registry's, and sharing would put its retention rule and the
  # backups' retention rule in one place, where the second one written wins and
  # the first silently stops applying.
  #
  # Per environment after all, which reverses the reasoning this comment used to
  # carry. It said promoting UAT's exact image to production was the point, so
  # one registry had to serve both.
  #
  # That only holds if the two environments run the same architecture, and they
  # need not: `@arm_default` is fsn1 and `@x86_default` is ash, `architecture_for/3`
  # is answered per environment, and `Builder` refuses an image built for the
  # wrong one. A binary cannot be promoted across architectures — so promotion
  # is the same *commit*, rebuilt for the target, and each environment needs
  # its own registry on its own box.
  #
  # Two `distribution` instances cannot share one bucket either: the registry
  # keeps its state there, and two writers would corrupt it.
  # Public because "whose bucket holds this project's images" is the claim the
  # per-customer decision rests on, and a private function makes it assertable
  # only through a stubbed `Storage`.
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
        # Same refusal as `Storage.bucket_name/2`, for the same reason: bucket
        # names are unique per account, so a generic fallback would be one
        # bucket shared by every unnamed project.
        raise ArgumentError, "cannot derive a registry bucket name: the project has no name"
    end
  end

  defp configured_bucket,
    do: Application.get_env(:code_my_spec, __MODULE__, [])[:bucket]

  defp repository(scope, opts) do
    case Keyword.get(opts, :repository) || project_slug(scope) do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _ -> {:error, :no_project}
    end
  end

  # Loopback on whichever box is asking, which is the whole point: the deploy
  # pulls it on the app's server, the builder pushes it through a tunnel to
  # that same port, and the string is identical at both ends because an image
  # reference is baked into the image and cannot differ between push and pull.
  #
  # A default rather than configuration. The shared design required a
  # `:registry_host` nobody had set, so `reference/3` answered
  # `{:error, :no_registry_host}` and the deploy step failed with it — a
  # blocker that existed only because the address was a deployment detail. It
  # is not one any more.
  #
  # `:registry_host`, not `:host`. The deploy step hands its whole opts list to
  # `reference/3`, and `:host` there is already the app's own hostname — so
  # reading it would have addressed every image at the customer's domain
  # instead of the registry, and the deploy would have tried to pull from
  # itself.
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

  Public because the builder's tunnel and the container's port mapping have to
  agree with the reference, and three places inventing 5000 separately is how
  they stop agreeing.
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

  The username is derived from the project, not a shared constant, now that
  the registry itself can be — one htpasswd file on a shared box holds an
  entry per project, and two projects both named `cms` could not both have a
  password in it.

  Minted once and kept in `ProjectSecrets`, like the age keys and the server
  key. kamal requires a registry password even when the registry would take
  anything — it refuses to render a config without one — and an unauthenticated
  registry then rejects the `docker login` it performs. So the registry has real
  credentials rather than a placeholder nobody checks.

  It is not much of a secret in itself: the registry listens on a private
  address inside one project's network. It is a real one anyway, because "only
  reachable from inside" is a property of today's firewall rather than of the
  registry.
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

  The half of what `serve/2` used to do unconditionally that is not any one
  project's concern: bringing up the `distribution` container itself,
  backed by whichever bucket the *first* project to reach this box supplied
  — sharing a box means sharing that registry process, the same as the
  database. Idempotent: an already-running container is left alone rather
  than restarted out from under whichever other project's app is pulling
  from it right now.

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
      {:ok, %{bucket: bucket, bind: bind, port: port()}}
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

  Project-side: never starts or touches the container itself — that is
  `ensure_container/2`'s job, run once for the box regardless of which
  project asks. Refuses instead of creating one if the container is not up
  yet, the same shape `Steps.server_creation_gate/3` uses for the server
  itself.

  `distribution` — the CNCF reference implementation of the registry API.
  There is nothing of ours in the serving path; this only tells an
  already-running daemon about one more tenant.

  Idempotent: this project's own htpasswd entry is upserted rather than
  assumed — the container may already be running with a different
  project's entry the first time this one reaches it.

  `:bind` is the address it listens on, loopback by default. That is the one
  knob the topology turns — a builder on another machine has to reach this
  port somehow, and where it binds decides whether that is a tunnel or a
  private address.

  `:run` takes the command and returns `{output, status}`, which is what makes
  the command assertable without a box.
  """
  @spec serve(Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def serve(%Scope{} = scope, opts \\ []) do
    run = Keyword.fetch!(opts, :run)
    bind = Keyword.get(opts, :bind, "127.0.0.1")

    with true <- container_running?(run) || {:error, :registry_not_provisioned},
         {:ok, credential} <- serve_credential(scope, opts),
         :ok <- ensure_htpasswd(run, credential, opts) do
      bucket = bucket_name(scope, opts)

      # This box pulls from the registry it is about to host, so it needs the
      # same exemption the builder does.
      run.([trust_command("#{bind}:#{port()}")])

      await_registry(run, bucket, bind, credential, Keyword.get(opts, :registry_attempts, 15))
    end
  end

  # `docker ps -q` answers with nothing but container ID lines when it
  # succeeds — but ssh's own "Warning: Permanently added ... to the list of
  # known hosts" banner merges onto the same stream (`stderr_to_stdout: true`)
  # on every call, since `UserKnownHostsFile=/dev/null` guarantees ssh never
  # finds a host already known. Checking "is the output non-empty" answered
  # that banner, not the container list — confirmed live against
  # fuellytics-prod: it read a fresh box with nothing on it as already
  # running, and the create command never ran at all, not even attempted
  # (`docker images`/`docker ps -a` and dockerd's own journal showed no trace
  # of it). `Remote.ssh_args/2` silences the banner at the source; this also
  # refuses to be fooled by anything else that might land on the same stream.
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

  # Removes only this project's own prior line, if it has one, and appends
  # the current one — every other project's entry in the file is untouched.
  # `|| true` on the filter step: `grep -v` exits 1 when nothing survives the
  # filter (the file held only this project's line), which is not a failure
  # here, just an empty starting point for the line about to be appended.
  #
  # The final write is `cat tmp > path`, never `mv tmp path`. The registry
  # container has this file bind-mounted, and a bind mount tracks the inode
  # that was at `path` when the container started, not the path itself. `mv`
  # (rename) points the path at the tmp file's *new* inode and detaches the
  # old one — the host sees the update, but a container whose mount predates
  # the rename keeps reading the orphaned original inode forever, with no
  # error, no matter how many times the file is rewritten afterward. `cat >`
  # truncates and rewrites the existing inode in place, so an already-running
  # container's next read of the file picks up the change with no restart.
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

  # `docker run -d` returning 0 means the container was *created*, not that it
  # is up — a bind to an address the interface does not carry yet fails after
  # the daemon has already answered, and the container exits behind a
  # successful command. The push then times out against nothing, which reads as
  # an unreachable host.
  #
  # Same distinction teardown draws for deletions: accepted is not done. So
  # this asks the registry itself, and when it never answers it brings back the
  # container's own logs rather than a timeout — the reason is in them, and a
  # drill costs ten minutes to repeat.
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

  # The one question both `await_registry/5` and `reachable?/2` ask: does
  # something answer `/v2/` through the credential a stranger would be
  # rejected by. Shared so a caller asking "is it up right now" and `serve/2`
  # asking "did the container I just started come up" run the identical
  # check rather than two curls that could drift apart.
  defp probe(run, bind, credential) do
    auth = "#{credential.username}:#{credential.password}"

    case run.(["curl -sf -u #{shell_escape(auth)} http://#{bind}:#{port()}/v2/ > /dev/null"]) do
      {_output, 0} -> :ok
      _ -> :error
    end
  end

  @doc """
  Whether the registry actually answers on a box, right now.

  `serve/2` is the only thing that starts a registry, so it is the only step
  that can notice one never came up — and `verify(:server, …)` used to infer
  it from a Hetzner server listing plus a file read, which is satisfied by a
  box that exists and a `DATABASE_URL` left over from a previous run. Neither
  says anything about the container `serve/2` would have started (c1d8eaff).

  The same probe `await_registry/5` loops on after starting one, run once: a
  caller checking whether a registry is already up should get one curl's
  worth of latency, not fifteen.

  `:run` is required, the same as `serve/2` — how to reach the box is the
  caller's to supply, and a caller standing in a local fleet or a fake for
  the box supplies its own. `:bind` defaults to loopback, same as `serve/2`.
  """
  @spec reachable?(Scope.t(), keyword()) :: boolean()
  def reachable?(%Scope{} = scope, opts) do
    run = Keyword.fetch!(opts, :run)
    bind = Keyword.get(opts, :bind, "127.0.0.1")

    case serve_credential(scope, opts) do
      {:ok, credential} -> probe(run, bind, credential) == :ok
      _ -> false
    end
  end

  # Injectable for the same reason the storage credentials are: a criterion
  # about what the registry is told to do should not have to mint a project
  # secret to say so.
  defp serve_credential(scope, opts) do
    case Keyword.get(opts, :registry_credentials) do
      %{username: _, password: _} = credential -> {:ok, credential}
      _ -> credential(scope)
    end
  end

  @doc """
  Keep only the `keep_images/1` most recent images, deleting the rest and
  reclaiming the blobs only they held.

  `:filesystem` storage has no bucket for `Storage.put_lifecycle/4` to expire
  anything in, so nothing else prunes a volume that grows by one image every
  deploy forever. This is what makes criterion 8241 true under the design
  that's actually final rather than one still waiting on the S3 push-reliability
  fix.

  Each of this registry's tags is content-addressed and never reused — a
  push always mints a new tag from the commit it built, never overwrites an
  old one — so the mtime of a tag's own `_manifests/tags/<tag>/current/link`
  is the moment it was last pushed, with no push history to track ourselves.
  Newest first by that mtime, keep the front `keep_images`, delete an older
  tag by the manifest digest its own link file already names, and run the
  registry's own garbage-collect once to reclaim the blobs only the deleted
  manifests held — shared base layers other kept images still reference
  survive, the same layer-versus-manifest distinction `blobs_prefix/0`
  documents for the S3 side.

  A repository with nothing pushed yet has no `_manifests/tags` directory at
  all; that is not a failure, there is simply nothing to prune. A deploy that
  just shipped must not fail because its own cleanup could not reach the box
  afterward — a caller gets `{:error, _}` back to log, not to propagate.
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

  # One shell invocation inside the container, so the box's own idea of "what
  # exists and when" is what decides — the same reason `serve_command` builds
  # one string per real action rather than several. `[ -d ... ] || exit 0`
  # rather than letting a glob that matched nothing become a literal `*/`
  # `for` loop iterates over: a project with no images yet has no directory,
  # and that is nothing to prune, not an error.
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

  # Newest first. Tags sort no other way — they are short commit SHAs, not
  # timestamps — so recency only exists as the mtime the box already reads.
  #
  # A line whose first token is not an integer is not tag data — skip it
  # rather than crash. `run.()` falls back to a real SSH runner whenever no
  # `:run` override is supplied (see `prune_registry/3`), and a caller that
  # reaches an address answering with anything other than this exact script's
  # output (a banner, an error page, a stray log line) must not take the
  # whole deploy down over a step the module's own moduledoc already
  # documents as best-effort and non-fatal.
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

  # The digest is read off the tag's own link file rather than asked of the
  # API — it is the same value either way, and this is one `docker exec`
  # instead of a second authenticated HTTP round trip for something already
  # sitting in a file `tags_by_recency/2` just walked past.
  #
  # Best-effort: a tag whose delete fails is one `prune/2` did not get to
  # this time, not a reason to stop deleting the rest of the list. But
  # `prune/2` needs to know which — the manifest API answers 202 on an
  # actual delete, and this used to run `curl -sf` and discard the tuple
  # unread, so a 405 (what `distribution` answers when
  # `storage.delete.enabled` is off) was indistinguishable from success:
  # `prune/2` reported every attempted tag as pruned regardless (9656c705).
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

  # Deleting a manifest unlinks its tag but leaves the layers on disk until
  # this runs — blobs are only reclaimed once nothing references them. No
  # `-m`: that flag also sweeps manifests no tag ever pointed at, which is a
  # different claim than "keep the last N" and not one this makes.
  defp garbage_collect(run) do
    case run.([
           "docker exec #{@container} /bin/registry garbage-collect /etc/distribution/config.yml"
         ]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:prune_gc_failed, status, String.trim(output)}}
    end
  end

  # Hetzner's object storage is S3-compatible but not S3: it needs path-style
  # addressing, and a virtual-host-style request reaches a bucket that does not
  # exist rather than failing usefully.
  #
  # `--restart always` because the registry has to survive a reboot of the box
  # it shares with the app. A deploy that cannot pull is a deploy that cannot
  # roll back, and the moment you need a rollback is not the moment to discover
  # the registry went away with the last kernel update.
  #
  # Only ever built for a container `ensure_container/5` has already confirmed
  # is not running — the htpasswd file it mounts is `ensure_htpasswd/3`'s, kept
  # current independently of whether this ever runs again after the first
  # project on a box creates it.
  defp create_container_command(bucket, credentials, bind, location, opts) do
    image = Keyword.get(opts, :registry_image, "registry:3")

    env =
      opts
      |> Keyword.get(:storage, :filesystem)
      |> storage_env(bucket, credentials, location)
      |> Enum.map_join(" ", fn {name, value} -> "-e #{name}=#{shell_escape(value)}" end)

    # `:auth_dir` defaults to the real box's path, but is overridable: on
    # `local_runner`, `mkdir`/`printf` run on the host while the bind mount
    # resolves inside a VM (Colima) with a different filesystem, so
    # `/etc/cms-registry` written on the host is invisible to the mount and
    # Docker creates a directory there instead of finding the file —
    # `baseline_local_test`'s own real failure mode. 8dcb9751.
    auth_dir = Keyword.get(opts, :auth_dir, "/etc/cms-registry")

    # `REGISTRY_STORAGE_DELETE_ENABLED=true` — without it `DELETE
    # /v2/<repo>/manifests/<digest>` answers 405 regardless of what the
    # image's baked-in config.yml says (that file is never rewritten; env
    # vars are merged in at startup), so `prune/2` ran every deploy and
    # deleted nothing. 9656c705.
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

  Docker assumes HTTPS for every registry except `localhost`, so a private
  address gets a TLS handshake against a plain-HTTP server and fails with
  `context deadline exceeded` — a timeout, which reads like an unreachable
  host rather than a protocol disagreement.

  Both ends need it: the builder to push, the app's box to pull.

  No TLS instead of TLS because there is nothing to protect. The registry
  listens on a private address inside one project's network, reachable only by
  machines we attached to it, and a certificate would need issuing, renewing
  and trusting on boxes that exist for one build.

  Restarted only when the file changes, since restarting Docker stops
  everything running on the box — which on the app's server is the app.
  """
  @spec trust_command(String.t()) :: String.t()
  def trust_command(host) do
    config = ~s({"insecure-registries":["#{host}"]})

    "mkdir -p /etc/docker && " <>
      "(grep -qF #{shell_escape(host)} /etc/docker/daemon.json 2>/dev/null || " <>
      "(echo #{shell_escape(config)} > /etc/docker/daemon.json && systemctl restart docker))"
  end

  # `distribution` takes its backing store from the environment, and which
  # store is a real configuration axis rather than a constant — not because
  # S3 is meant to run for real (it isn't, see `storage_env(:filesystem, ...)`
  # below) but because the tests below need a real assertion surface for what
  # was tried and rejected, and `:s3` stays reachable behind `storage: :s3`
  # for whoever revisits Hetzner's eventual consistency later.
  #
  # Hetzner's object storage is S3-compatible but not S3: it needs path-style
  # addressing, and a virtual-host-style request reaches a bucket that does not
  # exist rather than failing usefully.
  defp storage_env(:s3, bucket, credentials, location) do
    [
      {"REGISTRY_STORAGE", "s3"},
      {"REGISTRY_STORAGE_S3_REGION", location},
      {"REGISTRY_STORAGE_S3_REGIONENDPOINT", "https://#{location}.your-objectstorage.com"},
      {"REGISTRY_STORAGE_S3_FORCEPATHSTYLE", "true"},
      {"REGISTRY_STORAGE_S3_BUCKET", bucket},
      {"REGISTRY_STORAGE_S3_ACCESSKEY", Keyword.fetch!(credentials, :access_key_id)},
      {"REGISTRY_STORAGE_S3_SECRETKEY", Keyword.fetch!(credentials, :secret_access_key)},
      # Hetzner's object storage is eventually consistent, and a push reads
      # back what it has just written: the registry writes a layer, immediately
      # asks whether the blob exists, and gets told it does not. Docker reports
      # that as `unknown blob` after retrying each layer for a minute — some
      # layers pushed, others never did, and nothing in the message names
      # storage.
      #
      # The descriptor cache answers those reads from memory instead of going
      # back to the bucket, which is what the upstream registry recommends for
      # any S3-compatible backend that is not S3. It is a cache of what this
      # container itself just wrote, so it cannot serve a stale answer about
      # somebody else's push.
      #
      # Same family as the lifecycle-rule retry in `Storage.put_lifecycle/4`
      # and the bucket-gone poll in teardown: with this provider, "written" and
      # "readable" are separate moments.
      {"REGISTRY_STORAGE_CACHE_BLOBDESCRIPTOR", "inmemory"}
    ]
  end

  # The default and the final design, not a placeholder waiting on a fix for
  # the provider issue below. Backed by the project's Hetzner bucket, `docker
  # push` failed with `unknown blob` after retrying individual layers for a
  # minute: the registry writes a layer to an eventually consistent store,
  # immediately asks whether the blob exists, and is told it does not. Some
  # layers land, others never do. A descriptor cache is not enough — it
  # caches what the registry knows, not what the bucket will admit to.
  #
  # A volume on the box has none of that. What it gives up is the registry
  # surviving the box, and images are rebuildable from a commit — an old build
  # is not worth an unreliable push. Retention — the other thing a bucket
  # would have given this for free — is `Registry.prune/2`'s job instead:
  # keep the last `keep_images`, delete the rest by manifest digest, and run
  # the registry's own garbage-collect.
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
