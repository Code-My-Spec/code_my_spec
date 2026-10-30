defmodule CodeMySpec.Provisioning.Builder do
  @moduledoc """
  Build a project's image on the environment's one shared burst box.

  Nothing is built when a project is created; building happens at deploy,
  the only moment anyone knows what to build.

  `build/3` asks `BurstBox.ensure_box/3` for the account's one persistent box
  and, after every build, asks `BurstBox.Lifecycle.check/3` whether to free it.
  Builds from different projects run as separate Docker containers on that
  box; `RunLock` (held above this module) serializes same-project builds.

  Publishing is `Registry`'s. This owns the build.
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.BurstBox
  alias CodeMySpec.Provisioning.BurstBox.Lifecycle
  alias CodeMySpec.Provisioning.Deploy
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  defmodule Build do
    @moduledoc "What a finished build produced, and what it cost."

    @type t :: %__MODULE__{
            image: String.t(),
            architecture: :arm | :x86,
            builder: String.t(),
            builder_image: String.t(),
            builder_destroyed: boolean(),
            built_at: DateTime.t(),
            deploy: term()
          }

    defstruct [
      :image,
      :architecture,
      :builder,
      :builder_image,
      :builder_destroyed,
      :built_at,
      :deploy
    ]
  end

  # Build on the architecture the image will run on: a foreign-architecture
  # image fails only at container start. Sizes are a step up from the app
  # servers (a build is CPU-bound and short). cpx31 rather than the identical
  # cpx32 because cpx31 exists in every location.
  # See knowledge/provisioning, "Builder".
  @builders %{
    arm: %{server_type: "cax21", location: "fsn1"},
    x86: %{server_type: "cpx31", location: "fsn1"}
  }

  # A Hetzner label is how a snapshot is found again without storing its id.
  @burst_box_image_label "cms-burst-image-role"

  # A populated disk takes a long time to snapshot: up to ~20 minutes, backing
  # off from 5s to 30s.
  @default_image_poll_attempts 60
  @default_image_poll_interval_ms 5_000
  @default_image_poll_backoff_factor 1.5
  @default_image_poll_max_interval_ms 30_000

  # Marks a temp bootstrap server while its snapshot's outcome is unknown, so
  # `BurstBox.Sweep` can find it later without reaping it mid-poll. Value is
  # the architecture.
  @bootstrap_role_label "cms-bootstrap-role"

  @deploy_builder_label "cms-deploy-builder"

  @doc "Label added to burst boxes created for a deploy build."
  def deploy_builder_label, do: @deploy_builder_label

  @doc "The label `BurstBox.Sweep` looks for to find a temp bootstrap server whose snapshot outcome is not yet confirmed."
  @spec bootstrap_role_label() :: String.t()
  def bootstrap_role_label, do: @bootstrap_role_label

  @doc """
  Build `ref` for `architecture` on the environment's one shared burst box,
  freeing it the moment this build is the last thing using it.

  `:build_fun` is injectable because a container build is a bad thing to
  record (huge output, non-deterministic digests). The Hetzner calls stay
  real: "the box was checked after every build — success, failure or raise"
  is the claim that costs money when it silently stops being true.
  """
  @spec build(Scope.t(), String.t(), keyword()) :: {:ok, Build.t()} | {:error, term()}
  def build(%Scope{} = scope, ref, opts \\ []) when is_binary(ref) do
    architecture = Keyword.get(opts, :architecture)

    with {:ok, spec} <- builder_spec(architecture),
         {:ok, server} <- ensure_box(scope, architecture, spec, opts) do
      Logger.info(
        "[Builder] #{architecture} burst box #{server_name(server)} is up — building #{ref}"
      )

      # The box is shared, so every path — raise, non-zero exit, early return —
      # asks whether to free it.
      try do
        result = run(scope, server, ref, architecture, opts)
        log_build_outcome(result, server)
        record_disposition(result, server, release_box(scope, server, opts))
      rescue
        error ->
          _ = release_box(scope, server, opts)
          reraise error, __STACKTRACE__
      catch
        kind, value ->
          _ = release_box(scope, server, opts)
          :erlang.raise(kind, value, __STACKTRACE__)
      end
    end
  end

  # `:server_type`/`:location` forwarded so a box that has to be created gets
  # builder sizing rather than `BurstBox.ensure_box/3`'s app-server default.
  defp ensure_box(scope, architecture, spec, opts) do
    ensure = Keyword.get(opts, :ensure_box, &BurstBox.ensure_box/3)

    box_opts =
      opts
      |> Keyword.put(:architecture, architecture)
      |> Keyword.put(:server_type, Keyword.get(opts, :server_type) || spec.server_type)
      |> Keyword.put(:location, Keyword.get(opts, :builder_location) || spec.location)
      |> Keyword.update(
        :labels,
        %{@deploy_builder_label => "true"},
        &Map.put(&1, @deploy_builder_label, "true")
      )

    with {:ok, server} <- ensure.(scope, BurstBox.box_name(architecture), box_opts) do
      join_networks(scope, server, opts)
    end
  end

  # The box is the account's one, so it already exists for every build after
  # the first, and `:network_ids` only reaches Hetzner when a box is created.
  # A box made for uat's network then built for prod and could not reach
  # prod's registry ("Client.Timeout exceeded" on docker login).
  defp join_networks(scope, server, opts) do
    attached = for net <- server["private_net"] || [], do: net["network"]

    case (Keyword.get(opts, :network_ids) || []) -- attached do
      [] ->
        {:ok, server}

      missing ->
        attach = Keyword.get(opts, :attach_to_network, &Hetzner.attach_to_network/3)
        find = Keyword.get(opts, :find, &Hetzner.find_server/2)

        with :ok <- attach_all(scope, server["id"], missing, attach) do
          find.(scope, server["name"])
        end
    end
  end

  defp attach_all(scope, server_id, network_ids, attach) do
    Enum.reduce_while(network_ids, :ok, fn network_id, :ok ->
      case attach.(scope, server_id, network_id) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A deploy-created box is checked immediately after the build and deploy
  # callback. `BurstBox.Sweep` covers an interrupted process.
  defp release_box(scope, server, opts) do
    busy? = Keyword.get(opts, :busy?, &BurstBox.busy?/2)
    destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    force? = Map.get(server, "labels", %{})[@deploy_builder_label] == "true"
    Lifecycle.check(scope, server, busy?: busy?, destroy: destroy, now: now, force?: force?)
  end

  # The only line that says a build finished, one way or the other — otherwise
  # "silent" and "still going" read identically in the logs.
  defp log_build_outcome({:ok, %Build{} = build}, server) do
    Logger.info("[Builder] #{server_name(server)} built #{build.image}")
  end

  defp log_build_outcome({:error, reason}, server) do
    Logger.warning("[Builder] #{server_name(server)} failed: #{inspect(reason)}")
  end

  # `builder_destroyed` is what `release_box/3` decided (`:deleted` → true).
  # `builder_image` is read off the box's own Hetzner record.
  defp record_disposition({:ok, %Build{} = build}, server, disposition) do
    {:ok,
     %{build | builder_destroyed: disposition == :deleted, builder_image: server_image(server)}}
  end

  # A failed build reports its disposition too: a box left running an extra
  # billed hour is invisible behind an already-failed deploy.
  defp record_disposition({:error, reason}, server, disposition) do
    {:error, reason,
     %{
       builder: server_name(server),
       builder_image: server_image(server),
       builder_destroyed: disposition == :deleted
     }}
  end

  defp record_disposition(other, _server, _disposition), do: other

  defp builder_spec(architecture) do
    case Map.fetch(@builders, architecture) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_architecture, architecture}}
    end
  end

  @doc """
  The burst box's own snapshot for `architecture` — docker-ce, kamal, and this
  app's own OTP release installed on the box — found by label if one exists,
  built once if not.

  The release sits on the box itself because the app's own embedding jobs run
  there as FLAME runners; customer builds still run in throwaway Docker
  containers.

  `:install_release` is required: `(run, server, opts -> :ok | {:error, term()})`,
  called once after kamal and before the disk is synced for the snapshot.
  This module does not know how a release is built.

  One snapshot per Hetzner account: `list_images/2` is scoped to the calling
  account's token.
  """
  @spec ensure_burst_box_image(Scope.t(), :arm | :x86, keyword()) ::
          {:ok, String.t() | integer()} | {:error, term()}
  def ensure_burst_box_image(%Scope{} = scope, architecture, opts \\ []) do
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    selector = "#{@burst_box_image_label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, [image | _]} -> {:ok, image["id"]}
      {:ok, []} -> build_burst_box_image(scope, architecture, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Whether an available burst-box snapshot already exists for `architecture`.

  Used by `BurstBox.Sweep`: once true, a lingering `@bootstrap_role_label`
  server for this architecture is a leftover safe to reap rather than one
  still waiting on a snapshot.
  """
  @spec burst_box_image_available?(Scope.t(), :arm | :x86, keyword()) :: boolean()
  def burst_box_image_available?(%Scope{} = scope, architecture, opts \\ []) do
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    selector = "#{@burst_box_image_label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  # A temporary box, bootstrapped and snapshotted, then destroyed.
  defp build_burst_box_image(scope, architecture, opts) do
    with {:ok, spec} <- builder_spec(architecture) do
      create = Keyword.get(opts, :create, &Hetzner.create_server/3)
      destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
      create_image = Keyword.get(opts, :create_image, &Hetzner.create_image/3)
      install_release = Keyword.fetch!(opts, :install_release)
      name = "cms-burst-bootstrap-#{architecture}-#{System.unique_integer([:positive])}"

      create_opts = [
        server_type: spec.server_type,
        location: Keyword.get(opts, :builder_location) || spec.location,
        # The `docker-ce` marketplace image, which already has Docker.
        image: "docker-ce",
        ssh_key_ids: Keyword.get(opts, :ssh_key_ids),
        network_ids: Keyword.get(opts, :network_ids),
        labels: %{@bootstrap_role_label => to_string(architecture)}
      ]

      case create.(scope, name, create_opts) do
        {:ok, server} ->
          opts =
            opts
            |> Keyword.put(:image_label, @burst_box_image_label)
            |> Keyword.put(:extra_bootstrap, install_release)
            |> Keyword.put_new(
              :image_description,
              "CodeMySpec burst box (#{architecture})"
            )

          bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # The source server is not destroyed until its snapshot is confirmed. A
  # failure before `create_image` returned an id destroys it here; anything
  # after hands off to `finish_snapshot/8`.
  # See knowledge/provisioning, "Burst box image".
  defp bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    attempts = Keyword.get(opts, :ssh_attempts, 90)
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    label = Keyword.fetch!(opts, :image_label)
    description = Keyword.fetch!(opts, :image_description)

    with :ok <- Remote.await_ssh(run, attempts, opts),
         :ok <- Remote.ensure_kamal(run),
         :ok <- maybe_extra_bootstrap(run, server, opts),
         :ok <- sync_disk(run),
         {:ok, %{"image" => image}} <-
           create_image.(scope, server_id(server),
             description: description,
             labels: %{label => to_string(architecture)}
           ) do
      finish_snapshot(scope, server, architecture, destroy, list_images, image, label, opts)
    else
      error ->
        destroy_temp_server(destroy, scope, server, architecture)
        error
    end
  end

  # Destroys the source only on a confirmed outcome: the image is available, or
  # Hetzner dropped it. A poll that ran out leaves the source running and names
  # it in the error.
  defp finish_snapshot(scope, server, architecture, destroy, list_images, image, label, opts) do
    case await_image_ready(list_images, scope, image["id"], architecture, label, opts) do
      :ok ->
        destroy_temp_server(destroy, scope, server, architecture)
        {:ok, image["id"]}

      {:error, {:image_vanished, _id}} = error ->
        destroy_temp_server(destroy, scope, server, architecture)
        error

      {:error, reason} ->
        Logger.error(
          "[Builder] #{architecture} burst-box image #{inspect(image["id"])} was not " <>
            "confirmed ready (#{inspect(reason)}) — leaving bootstrap server " <>
            "#{server_id(server)} (#{inspect(server_name(server))}) running rather than " <>
            "risk deleting it while the snapshot may still be mid-write. Check Hetzner's " <>
            "own status for that image, then either destroy the server by hand (mix " <>
            "cms.provisioning_leaks) or re-run once it is clear which way the snapshot went."
        )

        {:error, {:image_not_confirmed, image["id"], server_id(server)}}
    end
  end

  defp maybe_extra_bootstrap(run, server, opts) do
    case Keyword.get(opts, :extra_bootstrap) do
      nil -> :ok
      step -> step.(run, server, opts)
    end
  end

  # Flush the page cache before Hetzner snapshots the block device; an exit 0
  # does not mean the writes reached disk. Never fatal — logged and continued.
  # See knowledge/provisioning, "Burst box image".
  defp sync_disk(run) do
    case run.(["sync"]) do
      {_, 0} ->
        :ok

      {output, status} ->
        Logger.warning(
          "[Builder] sync before snapshot reported exit #{status}: #{String.trim(output)}"
        )

        :ok
    end
  end

  # A failed cleanup is logged loudly, not returned: it must not fail a
  # successful image build, but it must not vanish either.
  defp destroy_temp_server(destroy, scope, server, architecture) do
    case destroy.(scope, server_id(server)) do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "[Builder] could not destroy temporary #{architecture} bootstrap server " <>
            "#{server_id(server)} after building its image: #{inspect(other)}. " <>
            "It is still running and being billed; delete it manually or via " <>
            "mix cms.provisioning_leaks."
        )
    end
  end

  # A plain poll for the image by exact id, without a `status` filter: it has
  # to tell "still creating" from "dropped", which an `available` filter
  # collapses into the same empty list.
  defp await_image_ready(list_images, scope, image_id, architecture, label, opts) do
    attempts = Keyword.get(opts, :image_poll_attempts, @default_image_poll_attempts)
    interval = Keyword.get(opts, :image_poll_interval_ms, @default_image_poll_interval_ms)
    poll_image_ready(list_images, scope, image_id, architecture, label, opts, attempts, interval)
  end

  defp poll_image_ready(
         _list_images,
         _scope,
         image_id,
         _architecture,
         _label,
         _opts,
         0,
         _interval
       ) do
    {:error, {:image_not_ready, image_id}}
  end

  defp poll_image_ready(
         list_images,
         scope,
         image_id,
         architecture,
         label,
         opts,
         attempts,
         interval
       ) do
    selector = "#{label}=#{architecture}"

    case list_images.(scope, label_selector: selector) do
      {:ok, images} ->
        case Enum.find(images, &(&1["id"] == image_id)) do
          %{"status" => "available"} ->
            :ok

          %{} ->
            Wait.sleep(interval)
            next_interval = min(round(interval * backoff_factor(opts)), max_interval(opts))

            poll_image_ready(
              list_images,
              scope,
              image_id,
              architecture,
              label,
              opts,
              attempts - 1,
              next_interval
            )

          nil ->
            {:error, {:image_vanished, image_id}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp backoff_factor(opts),
    do: Keyword.get(opts, :image_poll_backoff_factor, @default_image_poll_backoff_factor)

  defp max_interval(opts),
    do: Keyword.get(opts, :image_poll_max_interval_ms, @default_image_poll_max_interval_ms)

  defp run(scope, server, ref, architecture, opts) do
    # `:build_fun`, not `:build`: in the deploy step's opts `:build` is the
    # boolean asking whether to build at all.
    build_fun =
      Keyword.get(opts, :build_fun, fn scope, server, ref, architecture ->
        docker_build(scope, server, ref, architecture, opts)
      end)

    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    with {:ok, image} <- build_fun.(scope, server, ref, architecture),
         :ok <- matches?(image, architecture, opts) do
      {:ok,
       %Build{
         image: image.reference,
         architecture: image.architecture,
         builder: server_name(server),
         built_at: now.(),
         deploy: run_then(server, opts)
       }}
    end
  end

  # `:then` runs on the same box over the same SSH as the build — never on the
  # caller's machine (a harness cannot shell out). `nil` when not asked for,
  # which is the ordinary case. A kamal install failure is returned as a
  # `Deploy.Result` so the deploy step's `%{deploy: %Deploy.Result{}}` clause
  # still matches.
  defp run_then(server, opts) do
    case Keyword.get(opts, :then) do
      nil ->
        nil

      then_fun ->
        run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)

        case Remote.ensure_kamal(run) do
          :ok ->
            then_fun.(run, Keyword.get(opts, :build_dir, "/build"))

          {:error, {status, output}} ->
            %Deploy.Result{
              failed_phase: :build,
              reason: "could not install kamal on the builder (exit #{status}): #{output}"
            }
        end
    end
  end

  # A wrong-architecture image fails only at container start, long after the
  # deploy decided it was going well. Caught here so it is never published.
  defp matches?(%{architecture: architecture}, architecture, _opts), do: :ok

  defp matches?(%{architecture: built}, wanted, _opts),
    do: {:error, {:architecture_mismatch, built: built, wanted: wanted}}

  # Everything that is not the box — source, image destination, keys — arrives
  # in `opts`; the builder does not know how a project is addressed.
  defp docker_build(scope, server, ref, _architecture, opts) do
    case Keyword.get(opts, :reference) do
      nil ->
        {:error, :no_image_reference}

      reference ->
        Remote.build(server, ref, reference, with_deliver(opts, server, scope))
    end
  end

  # A harness copy's checkout is on another machine, where `git archive` cannot
  # be run for us, so its source comes from GitHub like a copy with none.
  @doc false
  def with_deliver(opts, server, scope) do
    case Keyword.get(opts, :env) do
      %{type: :harness} ->
        github_delivery(opts, server, scope)

      %{cwd: cwd} when is_binary(cwd) and cwd != "" ->
        opts

      _ ->
        github_delivery(opts, server, scope)
    end
  end

  defp github_delivery(opts, server, scope) do
    case github_source(scope) do
      {:ok, repo, token} ->
        opts
        |> Keyword.put(:github_repo, repo)
        |> Keyword.put(:github_token, token)
        |> then(&Keyword.put(&1, :deliver, Remote.github_deliver(server, &1)))

      {:error, reason} ->
        Keyword.put(opts, :deliver, fn _ref, _dir ->
          {:error, {:source_delivery_failed, :no_reachable_source, inspect(reason)}}
        end)
    end
  end

  defp github_source(%Scope{active_project: %{code_repo: url}} = scope)
       when is_binary(url) and url != "" do
    with {:ok, token} <- Integrations.fetch_access_token(scope, :github) do
      {:ok, repo_path(url), token}
    end
  end

  defp github_source(_scope), do: {:error, :no_repository}

  defp repo_path(url) do
    url
    |> String.trim_trailing(".git")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp server_name(%{"name" => name}), do: name
  defp server_name(%{"server" => %{"name" => name}}), do: name
  defp server_name(_), do: nil

  # Read off the box's own Hetzner record; `"unknown"` when it does not say.
  defp server_image(%{"image" => %{"description" => description}})
       when is_binary(description) and description != "",
       do: sanitize_image(description)

  defp server_image(%{"image" => %{"name" => name}}) when is_binary(name) and name != "",
    do: sanitize_image(name)

  defp server_image(%{"image" => %{"id" => id}}), do: to_string(id)
  defp server_image(%{"server" => server}), do: server_image(server)
  defp server_image(_server), do: "unknown"

  # Packed into a space-separated `key=value` identifier
  # (`ResourceFields.identifier_field/2`), so it must be one token.
  defp sanitize_image(value), do: String.replace(value, " ", "_")
end
