defmodule CodeMySpec.Provisioning.Registry do
  @moduledoc """
  Where built images live, and how they stop costing money.

  A registry per customer, on the box the customer's app already runs on,
  backed by the customer's own bucket.

  This was the other way round first — one shared registry of ours, one shared
  bucket, a repository per project — on the reasoning that story 992 is called
  *my images are built on infrastructure I never maintain*, so a bucket Sam
  pays for holding a registry Sam's lifecycle rule prunes would be
  infrastructure Sam maintains.

  That argument does not survive contact with what we already install on his
  box. Setup puts Docker, kamal-proxy, a firewall and TLS there and he touches
  none of it. A registry container is the same kind of thing: provisioned by
  us, operated by us, never opened by him. "Infrastructure I never maintain"
  is about who operates it, not about whose account it bills to — read the
  other way, his application server would breach the promise too.

  What the shared version cost was real: another always-on box, a public
  hostname with a certificate, an auth secret to rotate, and one store holding
  every customer's application images. That last one is the reason this
  changed. Isolation is the acceptance criterion for our multi-tenant work,
  and a bug in one registry's auth would leak every customer's proprietary
  code as a pullable image. Per-customer, the blast radius is one customer's
  own box.

  Both criteria are still met, and the module docstring for the shared design
  conceded as much — neither asked for sharing. 8240 wants a deploy that pulls
  without a GitHub credential: it pulls from `localhost`, so there is no
  credential at all. 8241 wants old images to expire without anyone
  remembering: retention is still the bucket lifecycle rule we have already
  written and debugged against Hetzner's Ceph, which is the part of running a
  registry that actually bites — they fill disks silently, because every image
  ever built stays until something deletes it.

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

  alias CodeMySpec.Provisioning.Storage
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
    with {:ok, host} <- host(opts),
         {:ok, repository} <- repository(scope, opts) do
      {:ok, "#{host}/#{repository}:#{tag}"}
    end
  end

  @doc "How long images are kept, in days."
  @spec retention_days(keyword()) :: pos_integer()
  def retention_days(opts), do: Keyword.get(opts, :retention_days, @default_retention_days)

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
  # `-registry`, not an environment suffix. `Storage.bucket_name/2` appends the
  # environment because each environment's data must not mix; images are the
  # opposite — promoting UAT's exact image to production is the point of the
  # release process, and two registries would mean rebuilding to promote,
  # which is how a promotion ships something that was never tested.
  # Public because "whose bucket holds this project's images" is the claim the
  # per-customer decision rests on, and a private function makes it assertable
  # only through a stubbed `Storage`.
  @doc "The bucket this project's images are stored in."
  @spec bucket_name(Scope.t(), keyword()) :: String.t()
  def bucket_name(%Scope{} = scope, opts \\ []) do
    Keyword.get(opts, :bucket) || configured_bucket() || derived_bucket_name(scope)
  end

  defp derived_bucket_name(scope) do
    case project_slug(scope) do
      slug when is_binary(slug) and slug != "" ->
        "#{slug}-registry"

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

  @doc """
  Run the registry on a server, backed by this project's bucket.

  `distribution` — the CNCF reference implementation of the registry API — as a
  container, with its S3 driver pointed at the bucket `ensure/2` made. There is
  nothing of ours in the serving path; this starts somebody else's daemon and
  tells it where its blobs live.

  Idempotent, because setup runs more than once: the container is replaced
  rather than added to, so a second run converges instead of failing on a name
  that is already taken.

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
    location = Keyword.get(opts, :location, "fsn1")

    with {:ok, credentials} <- credentials(scope, opts) do
      bucket = bucket_name(scope, opts)
      command = serve_command(bucket, credentials, bind, location, opts)

      # This box pulls from the registry it is about to host, so it needs the
      # same exemption the builder does.
      run.([trust_command("#{bind}:#{port()}")])

      case run.([command]) do
        {_output, 0} -> {:ok, %{bucket: bucket, bind: bind, port: port()}}
        {output, status} -> {:error, {:registry_start_failed, status, String.trim(output)}}
      end
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
  defp serve_command(bucket, credentials, bind, location, opts) do
    image = Keyword.get(opts, :registry_image, "registry:3")

    env =
      [
        {"REGISTRY_STORAGE", "s3"},
        {"REGISTRY_STORAGE_S3_REGION", location},
        {"REGISTRY_STORAGE_S3_REGIONENDPOINT",
         "https://#{location}.your-objectstorage.com"},
        {"REGISTRY_STORAGE_S3_FORCEPATHSTYLE", "true"},
        {"REGISTRY_STORAGE_S3_BUCKET", bucket},
        {"REGISTRY_STORAGE_S3_ACCESSKEY", Keyword.fetch!(credentials, :access_key_id)},
        {"REGISTRY_STORAGE_S3_SECRETKEY", Keyword.fetch!(credentials, :secret_access_key)}
      ]
      |> Enum.map_join(" ", fn {name, value} -> "-e #{name}=#{shell_escape(value)}" end)

    "docker rm -f #{@container} >/dev/null 2>&1; " <>
      "docker run -d --name #{@container} --restart always " <>
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

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp project_slug(%Scope{active_project: %{name: name}}) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp project_slug(_scope), do: nil
end
