defmodule CodeMySpec.Provisioning.BurstBox do
  @moduledoc """
  Find-or-create the one persistent burst box an account has, and start or
  stop a bare release process on it.

  Provides the closures `CodeMySpec.Embeddings.HetznerFlameBackend` needs
  (`:ensure_box`/`:start_runner`/`:stop_runner`), plus `install_release/3` for
  `Builder.ensure_burst_box_image/3`. This is the mechanism;
  `BurstBox.Lifecycle`/`BurstBox.Sweep` are the policy.

  - `ensure_box/3` is one `Hetzner.find_server/2` call when the box exists
    (it is called on every runner boot); only the first call builds the
    snapshot and creates the server.
  - A box created for the platform's own scope (no account, no project) gets
    Fly 6PN peering from `config :code_my_spec, BurstBox.FlyPeering, peer:
    %{...}`, minted by hand with `flyctl wireguard create`. Absent config logs
    and leaves the box usable for builds only. Customer boxes are never
    peered.
  - A runner is the installed release started with `nohup … &` and a PID file
    keyed by runner name, so `stop_runner/4` kills only that process.

  See knowledge/provisioning, "Burst box".
  """

  require Logger

  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.BurstBox.FlyPeering
  alias CodeMySpec.Provisioning.BurstBox.Sweep
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  # Shared by `install_release/3` and `start_runner/5`.
  @release_path "/opt/cms-release"

  @doc "Where `install_release/3` extracts the release to, and `start_runner/5` runs it from."
  @spec release_path() :: String.t()
  def release_path, do: @release_path

  # Every caller must pass these names or an account ends up with extra boxes
  # (`Builder.build/3` and `HetznerFlameBackend`'s config in `application.ex`).
  # One box per architecture: a build runs natively, so an amd64 image cannot
  # come off the arm box.
  @box_name "burst-platform"

  @doc "The arm burst box name every caller should pass to `ensure_box/3`."
  @spec box_name() :: String.t()
  def box_name, do: @box_name

  @doc "The burst box name for builds on `architecture`."
  @spec box_name(:arm | :x86 | nil) :: String.t()
  def box_name(:x86), do: @box_name <> "-x86"
  def box_name(_arm), do: @box_name

  ## ensure_box

  @doc """
  Find the named burst box, creating (and, for our own environment, peering
  into Fly's 6PN) it only if absent.

  `opts`:

    * `:architecture` — `:arm` (default) or `:x86`, same meaning as
      everywhere else in `CodeMySpec.Provisioning`.
    * `:find` — defaults to `&Hetzner.find_server/2`.
    * `:create` — defaults to `&Hetzner.create_server/3`.
    * `:ensure_burst_box_image` — defaults to `&Builder.ensure_burst_box_image/3`.
    * `:install_release` — defaults to `&install_release/3`. Forwarded to
      `ensure_burst_box_image/3`, which requires it (with no default of its
      own) only on the first call for a given box, when there is no
      snapshot yet to boot from.
    * `:ssh_key_ids` / `:network_ids` — forwarded to `Hetzner.create_server/3`
      unchanged; this module does not know a project's own resources.
    * `:fly_peer` — overrides the application-config peer, for a test or a
      caller that already resolved one.
    * `:run` — overrides the SSH runner used for Fly peering, for a test.

  Every other key is forwarded as-is to `ensure_burst_box_image/3` (and from
  there to `Builder.Remote.ssh_runner/2` for whatever SSH options it needs),
  so a real caller configures this exactly the way it already configures
  `Builder.build/3`.
  """
  @spec ensure_box(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_box(%Scope{} = scope, box_name, opts \\ []) when is_binary(box_name) do
    find = Keyword.get(opts, :find, &Hetzner.find_server/2)

    case find.(scope, box_name) do
      {:ok, server} -> {:ok, server}
      {:error, :not_found} -> create_box(scope, box_name, opts)
      {:error, _} = error -> error
    end
  end

  defp create_box(scope, box_name, opts) do
    architecture = Keyword.get(opts, :architecture, :arm)
    ensure_image = Keyword.get(opts, :ensure_burst_box_image, &Builder.ensure_burst_box_image/3)
    create = Keyword.get(opts, :create, &Hetzner.create_server/3)
    image_opts = Keyword.put_new(opts, :install_release, &install_release/3)

    with {:ok, image} <- ensure_image.(scope, architecture, image_opts) do
      spec = Hetzner.defaults_for(architecture)

      create_opts =
        opts
        |> Keyword.take([:ssh_key_ids, :network_ids])
        |> Keyword.put(:image, image)
        |> Keyword.put(:server_type, Keyword.get(opts, :server_type) || spec.server_type)
        |> Keyword.put(:location, Keyword.get(opts, :location) || spec.location)
        |> Keyword.put(:labels, box_labels(opts))

      case create.(scope, box_name, create_opts) do
        {:ok, %{"server" => server}} -> {:ok, after_create(scope, server, opts)}
        {:error, _} = error -> error
      end
    end
  end

  defp box_labels(opts) do
    Map.merge(%{Sweep.role_label() => "true"}, Keyword.get(opts, :labels, %{}))
  end

  defp after_create(scope, server, opts) do
    if platform_scope?(scope) do
      apply_fly_peering(server, opts)
    end

    server
  end

  defp apply_fly_peering(server, opts) do
    case configured_fly_peer(opts) do
      nil ->
        Logger.warning(
          "[BurstBox] #{inspect(server["name"])} was just created for our own environment " <>
            "with no Fly peer configured (config :code_my_spec, #{inspect(FlyPeering)}, " <>
            "peer: %{...}) — its FLAME runners cannot dial back until one is set"
        )

      peer ->
        run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)

        case FlyPeering.apply(peer, run) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[BurstBox] could not apply Fly peering to #{inspect(server["name"])}: " <>
                "#{inspect(reason)}. The box exists but its FLAME runners cannot dial back."
            )
        end
    end
  end

  # No project, no account: the platform acting for itself.
  defp platform_scope?(%Scope{active_account_id: nil, active_project_id: nil}), do: true
  defp platform_scope?(%Scope{}), do: false

  defp configured_fly_peer(opts) do
    Keyword.get(opts, :fly_peer) ||
      :code_my_spec |> Application.get_env(FlyPeering, []) |> Keyword.get(:peer)
  end

  ## start_runner / stop_runner

  @doc """
  Start one new release process named `runner_name` on `server`, with `env`
  exported into it, detached so it survives this SSH session ending.

  `env` is what `HetznerFlameBackend` built (`FLAME_PARENT`,
  `PHX_SERVER=false`, extras); this adds `CMS_FLAME_RUNNER_NAME` (always) and
  `CMS_FLAME_RUNNER_IP` (when a Fly peer is configured), which
  `rel/env.sh.eex` builds `RELEASE_NODE` from.

  `opts`:

    * `:release_path` — overrides `release_path/0`, for a test.
    * `:run` — overrides the SSH runner, for a test.
    * `:fly_peer` / `:fly_peer_address` — override the configured peer /
      its address, for a test.

  Every other key reaches `Builder.Remote.ssh_runner/2` unchanged when no
  `:run` is given.
  """
  @spec start_runner(Scope.t(), map(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def start_runner(%Scope{} = _scope, server, runner_name, env, opts \\ [])
      when is_binary(runner_name) and is_map(env) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    dest = release_dir(opts)

    full_env =
      env
      |> Map.put("CMS_FLAME_RUNNER_NAME", runner_name)
      |> maybe_put_runner_ip(opts)

    command =
      "mkdir -p #{run_dir(dest)} && cd #{dest} && " <>
        "(#{env_prefix(full_env)} nohup #{dest}/bin/code_my_spec start </dev/null " <>
        ">#{log_path(dest, runner_name)} 2>&1 & echo $! >#{pid_path(dest, runner_name)})"

    case run.([command]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(to_string(output))}}
    end
  end

  @doc """
  Kill exactly the runner process `start_runner/5` started under
  `runner_name`, leaving the box and every other runner on it untouched.

  Found by its PID file rather than by matching `ps`; the file is removed
  either way so a reused name never reads a stale PID.
  """
  @spec stop_runner(Scope.t(), map(), String.t(), keyword()) :: :ok | {:error, term()}
  def stop_runner(%Scope{} = _scope, server, runner_name, opts \\ [])
      when is_binary(runner_name) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    pid_file = pid_path(release_dir(opts), runner_name)

    command =
      "if [ -f #{pid_file} ]; then kill \"$(cat #{pid_file})\" 2>/dev/null; rm -f #{pid_file}; fi"

    case run.([command]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(to_string(output))}}
    end
  end

  defp release_dir(opts), do: Keyword.get(opts, :release_path, @release_path)
  defp run_dir(dest), do: "#{dest}/run"
  defp pid_path(dest, runner_name), do: "#{run_dir(dest)}/#{runner_name}.pid"
  defp log_path(dest, runner_name), do: "#{run_dir(dest)}/#{runner_name}.log"

  ## busy?

  @doc """
  The real `:busy?` for `BurstBox.Lifecycle.check/3`. True when either:

    * a CodeMySpec build is running on `server` (`build_in_progress?/3`);
    * `opts[:embed_runner_busy?]` returns true — the box's embedding runners,
      supplied as a function because `Embeddings` and `Provisioning` are
      top-level boundaries with no dependency between them.

  Defaults to `fn -> false end`, right for any box that never hosts
  embedding runners. The platform box's callers in `application.ex` pass one
  built from `CodeMySpec.Embeddings.InFlightCalls.any_in_flight?/1`.
  """
  @spec busy?(Scope.t(), map(), keyword()) :: boolean()
  def busy?(%Scope{} = scope, server, opts \\ []) do
    embed_runner_busy? = Keyword.get(opts, :embed_runner_busy?, fn -> false end)
    build_in_progress?(scope, server, opts) or embed_runner_busy?.()
  end

  @doc """
  Whether a CodeMySpec build is currently running on `server`: greps
  `docker ps` for `Remote.build/4`'s marker container label.

  A failed check reads as busy: `Lifecycle.check/3` acts only on `false`, so
  "unknown" costs an extra billed hour rather than deleting a box mid-build.
  """
  @spec build_in_progress?(Scope.t(), map(), keyword()) :: boolean()
  def build_in_progress?(%Scope{} = _scope, server, opts \\ []) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    label = Remote.build_marker_label()

    case run.(["docker ps -q --filter label=#{label}"]) do
      {output, 0} ->
        String.trim(output) != ""

      {output, status} ->
        Logger.warning(
          "[BurstBox] could not check #{server_label(server)} for an in-progress build: " <>
            "exit #{status}: #{String.trim(to_string(output))} — treating it as busy"
        )

        true
    end
  end

  defp server_label(%{"name" => name}), do: name
  defp server_label(%{"server" => server}), do: server_label(server)
  defp server_label(server), do: inspect(server)

  defp maybe_put_runner_ip(env, opts) do
    case Keyword.get(opts, :fly_peer_address) || configured_fly_peer_address(opts) do
      nil -> env
      address -> Map.put(env, "CMS_FLAME_RUNNER_IP", strip_cidr(address))
    end
  end

  defp configured_fly_peer_address(opts) do
    with peer when is_map(peer) <- configured_fly_peer(opts),
         address when is_binary(address) <- Map.get(peer, :address) do
      address
    else
      _ -> nil
    end
  end

  # Fly addresses carry a prefix ("fdaa:1:2::3/120"); RELEASE_NODE wants the
  # bare address.
  defp strip_cidr(address), do: address |> String.split("/") |> hd()

  defp env_prefix(env) do
    Enum.map_join(env, " ", fn {k, v} -> "#{k}=#{shell_quote(to_string(v))}" end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  ## install_release

  @doc """
  Build this app's own release for `opts[:ref]` with `Builder.Remote.build/4`
  (never pushed), check its architecture against
  `Hetzner.server_architecture/1` of `server`, then extract `/app` onto
  `release_path/0` with `docker create` + `docker cp` + `docker rm` — no
  running container.

  `opts[:ref]` is required: which commit to install is the caller's
  decision. Source delivery is whatever `Remote.build/4` supports
  (`opts[:deliver]`, or `opts[:env]`, or `opts[:github_repo]`/
  `opts[:github_token]`).
  """
  @spec install_release((list() -> {String.t(), non_neg_integer()}), map(), keyword()) ::
          :ok | {:error, term()}
  def install_release(run, server, opts) do
    ref = Keyword.fetch!(opts, :ref)
    image = "cms-release:#{ref}"
    build_opts = opts |> Keyword.put(:run, run) |> Keyword.put(:push, false)

    with {:ok, built} <- Remote.build(server, ref, image, build_opts),
         :ok <- check_architecture(server, built.architecture) do
      extract_release(run, image, release_dir(opts))
    end
  end

  defp check_architecture(server, built) do
    case Hetzner.server_architecture(server) do
      {:ok, ^built} -> :ok
      {:ok, wanted} -> {:error, {:architecture_mismatch, built: built, wanted: wanted}}
      # The box's own data did not say — proceed rather than refuse over a
      # check that could not be made.
      {:error, _reason} -> :ok
    end
  end

  defp extract_release(run, image, dest) do
    with {container, 0} <- run.(["docker create #{image}"]),
         id = String.trim(container),
         {_, 0} <- run.(["rm -rf #{dest} && docker cp #{id}:/app #{dest}"]),
         {_, 0} <- run.(["docker rm #{id}"]) do
      :ok
    else
      {output, status} ->
        {:error, {:release_extract_failed, status, String.trim(to_string(output))}}
    end
  end
end
