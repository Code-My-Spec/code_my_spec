defmodule CodeMySpec.Provisioning.BurstBox do
  @moduledoc """
  Find-or-create the one persistent burst box an environment has, and start
  or stop a bare release process on it (story 877, build order item after
  `Lifecycle`/`Sweep`/`FlyPeering`).

  This is the home for the three closures
  `CodeMySpec.Embeddings.HetznerFlameBackend`'s own moduledoc already
  specifies the contract for (`:ensure_box`/`:start_runner`/`:stop_runner`),
  plus `:install_release` — the closure
  `CodeMySpec.Provisioning.Builder.ensure_burst_box_image/3`'s moduledoc
  already specifies and leaves with no default. Parallel to `BurstBox.Lifecycle`
  /`BurstBox.Sweep`/`BurstBox.FlyPeering`, which already live in this
  namespace, for the same reason: this is the mechanism those modules'
  *policy* acts on, same split as `Hetzner` (the provider calls) versus
  `Provisioning` (the sequence).

  ## `ensure_box/3` is cheap when the box already exists, expensive the first time

  `HetznerFlameBackend.remote_boot/1` calls `:ensure_box` on every single
  runner boot, so the common case has to be one list call
  (`Hetzner.find_server/2`) and nothing else — the same idempotence
  `Hetzner.ensure_server/3` already gives every other box this codebase
  creates. Only the very first call for a given `box_name` pays for
  `Builder.ensure_burst_box_image/3` (find-or-build the snapshot) and
  `Hetzner.create_server/3`.

  ## Why Fly peering is applied here, and only for our own environment

  `BurstBox.FlyPeering`'s own moduledoc insists on staying isolated — called
  from nowhere `Lifecycle` or `Sweep` touch — so this module is the one
  caller, and only on the one path that needs it: a box being created for
  *our own* environment, never a customer's (a customer's box only ever runs
  their builds in Docker; nothing on it dials back to a Fly-hosted parent,
  because there is no Fly-hosted parent in a customer's own account).

  "Our own" is read off `scope` the same way the rest of this codebase
  already reads "no project, no account" scopes — `Hetzner.token/1`'s own
  fallback to application config exists for exactly this shape of scope, and
  `HetznerFlameBackend`'s moduledoc already shows the wiring as
  `platform_scope = %CodeMySpec.Users.Scope{}`. A scope carrying neither
  `active_account_id` nor `active_project_id` is the platform acting for
  itself; anything else is acting for a customer.

  The peer's own parameters (this box's assigned 6PN address, Fly's gateway,
  Fly's public key) are not minted here — nothing in this codebase talks to
  Fly's API (see `FlyPeering`'s own moduledoc) — so they come from
  application config, the same place `Hetzner.token/1` already falls back to
  for a platform-scoped credential with no account/project to hang a secret
  off of:

      config :code_my_spec, CodeMySpec.Provisioning.BurstBox.FlyPeering,
        peer: %{
          private_key: "...",
          address: "fdaa:1:2::3/120",
          peer_public_key: "...",
          endpoint: "fly-gateway.example.com:51820",
          allowed_ips: "fdaa::/16"
        }

  Set once, by a human running `flyctl wireguard create` once per
  environment — nothing here automates minting it. Absent config does not
  fail box creation (the box is still useful for our own builds without it);
  it logs loudly and leaves the box unreachable for FLAME runners until
  configured.

  ## `start_runner`/`stop_runner`: one bare OS process, found by name

  A runner here is the already-installed release (`install_release/3`
  having put it on disk at `release_path/0`) started as a plain backgrounded
  OS process — "our own embedding jobs ... run as FLAME runners, no
  container layer needed." `nohup` plus closed stdio is what lets it survive
  the SSH session that started it closing (the standard shape; `daemon`'s own
  built-in detachment was considered and rejected — see below) — and a PID
  file keyed by `runner_name` is what lets `stop_runner/4` find and kill
  *only* that one process later, leaving the box and every other runner on it
  untouched, which is `stop_runner/4`'s whole contract.

  `bin/<release> daemon` was the other option and is not used: it assumes one
  node per `RELEASE_ROOT`, with `run_erl`/`to_erl` paths that default to
  fixed locations under the release directory — fine for one release, wrong
  for many runner processes sharing the one release this module installs
  once. Plain `nohup ... &` plus an explicit PID file sidesteps that
  entirely: every runner's log and PID file is its own, named by
  `runner_name`, with nothing shared between them but the release's files.

  `CMS_FLAME_RUNNER_NAME` and `CMS_FLAME_RUNNER_IP` are exported into the
  runner's own environment, read by the new branch in `rel/env.sh.eex` to
  build `RELEASE_NODE` — see that file's own comment for why the *name* half
  has to be unique per runner even though every runner here shares the box's
  one IP (unlike Fly, where each machine already has its own). The IP half
  comes from the same configured Fly peer `ensure_box/3` applies, read back
  by its own `:address` rather than re-derived — one source of truth for
  "what address does this box answer FLAME runners on."
  """

  require Logger

  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.BurstBox.FlyPeering
  alias CodeMySpec.Provisioning.BurstBox.Sweep
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  # Where `install_release/3` puts the release's files, and where
  # `start_runner/5` expects to find them. One path, named once, because the
  # two functions disagreeing about it is exactly the kind of drift that only
  # shows up against a real box.
  @release_path "/opt/cms-release"

  @doc "Where `install_release/3` extracts the release to, and `start_runner/5` runs it from."
  @spec release_path() :: String.t()
  def release_path, do: @release_path

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

  # No project, no account: the platform acting for itself rather than on a
  # customer's behalf — the same shape `Hetzner.token/1`'s own fallback to
  # application config already reads as "nobody to scope a secret to."
  defp platform_scope?(%Scope{active_account_id: nil, active_project_id: nil}), do: true
  defp platform_scope?(%Scope{}), do: false

  defp configured_fly_peer(opts) do
    Keyword.get(opts, :fly_peer) ||
      (:code_my_spec |> Application.get_env(FlyPeering, []) |> Keyword.get(:peer))
  end

  ## start_runner / stop_runner

  @doc """
  Start one new release process named `runner_name` on `server`, with `env`
  exported into it, detached so it survives this SSH session ending.

  `env` is handed whatever `HetznerFlameBackend` built (`FLAME_PARENT`,
  `PHX_SERVER=false`, plus any caller extras) — this adds
  `CMS_FLAME_RUNNER_NAME` (always, `runner_name` itself) and
  `CMS_FLAME_RUNNER_IP` (when a Fly peer is configured — see the moduledoc)
  for `rel/env.sh.eex`'s own new branch to build `RELEASE_NODE` from.

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

  Found by its PID file rather than by pattern-matching `ps` — the file is
  the one record of which OS process this runner actually was, and it is
  removed either way so a later `start_runner/5` reusing the same name never
  reads a stale PID.
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
  The real `:busy?` for `BurstBox.Lifecycle.check/3` (story 877, item 1).

  True when either half says so:

    * a CodeMySpec build container is running on `server` right now — see
      `build_in_progress?/3`, checked over the same SSH every other function
      here already uses;
    * `opts[:embed_runner_busy?]` says so — the box's own embedding runners,
      answered by a caller-supplied `(-> boolean())` rather than this module
      reaching into `CodeMySpec.Embeddings` directly: both are `top_level?:
      true` boundaries with no dependency between them (see
      `HetznerFlameBackend`'s own moduledoc for why — the same forbidden-edge
      reasoning applies in this direction too), so the fact can only arrive
      as data, never as a call written in this module's own source.

  Defaults to `fn -> false end`, which is the right default for any box that
  never hosts embedding runners at all — every customer's box, and ours
  whenever nothing wires a real one in. Our own platform box's eager/sweep
  checks are the only callers that should ever pass a real one, built from
  `CodeMySpec.Embeddings.InFlightCalls.any_in_flight?/1` where both
  boundaries are already in scope (`application.ex`).
  """
  @spec busy?(Scope.t(), map(), keyword()) :: boolean()
  def busy?(%Scope{} = scope, server, opts \\ []) do
    embed_runner_busy? = Keyword.get(opts, :embed_runner_busy?, fn -> false end)
    build_in_progress?(scope, server, opts) or embed_runner_busy?.()
  end

  @doc """
  Whether a CodeMySpec build is currently running on `server` — the half of
  `busy?/3` any box, ours or a customer's, can answer on its own.

  Greps `docker ps` for the marker label `Remote.build/4` stamps on its own
  throwaway container for exactly the span a build is in flight (see that
  function's own comment for why a marker exists at all: a plain `docker
  build` is not `docker ps`-observable for its whole duration on its own).

  A failed check — the box unreachable, `docker` itself not answering —
  reads as busy rather than idle: the honest answer is "unknown," and
  `Lifecycle.check/3` only ever acts on `false`, so the safe default is the
  one that costs an extra billed hour rather than the one that risks
  deleting a box something is still building on.
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

  # Fly hands out an address with its own prefix (e.g. "fdaa:1:2::3/120",
  # matching `FlyPeering.config/1`'s own doctest) — RELEASE_NODE wants the
  # bare address.
  defp strip_cidr(address), do: address |> String.split("/") |> hd()

  defp env_prefix(env) do
    Enum.map_join(env, " ", fn {k, v} -> "#{k}=#{shell_quote(to_string(v))}" end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  ## install_release

  @doc """
  Build this app's own release for `opts[:ref]` the same way
  `Builder.Remote.build/4` already builds a customer's image, then extract
  the release's files onto `server`'s own filesystem — no running container,
  no pushed image.

  `opts[:ref]` is required, with no default — which commit this installs is
  not this module's decision any more than *how* to build one is
  `Builder.ensure_burst_box_image/3`'s (that function requires
  `:install_release` itself for the identical reason). Whoever wires this for
  real decides the ref — the currently-deployed commit, a tag, a fixed branch
  — and passes it through.

  Source delivery reuses whatever `Remote.build/4` already supports
  unchanged: an explicit `opts[:deliver]`, or its own default of
  `ssh_deliver/2` (needs `opts[:env]`, a reachable checkout) or
  `github_deliver/2` (needs `opts[:github_repo]`/`opts[:github_token]`) built
  by the caller — this app's own repository coordinates, not a customer's.

  The built image is never pushed (`push: false`, regardless of what `opts`
  says) and is read back for its actual architecture before anything is
  extracted — `Hetzner.server_architecture/1` against `server` itself, the
  same "read, don't assume" discipline `Builder`'s own `matches?/3` already
  applies to a customer build, so a build that quietly produced the wrong
  architecture is caught here rather than installed onto a box it will never
  run correctly on.

  Extraction is `docker create` (a container, never started) + `docker cp`
  (pull `/app` — the Dockerfile's own `WORKDIR`, see `Dockerfile`) + `docker
  rm` (discard the container), onto `release_path/0`.
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
      # The box's own data did not say — proceed rather than refuse an
      # install over a check that could not be made, the same reasoning
      # `Builder.bootstrap_and_snapshot/6`'s own `sync` failure is logged
      # and not fatal.
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
