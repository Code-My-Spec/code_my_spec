defmodule CodeMySpec.Embeddings.HetznerFlameBackend do
  @moduledoc """
  A `FLAME.Backend` that bursts `CodeMySpec.EmbedPool` runners onto ephemeral
  Hetzner Cloud servers, as a second, cheaper compute option alongside
  `FLAME.FlyBackend` (step 7, 577de9bb).

  **First draft, not wired up.** Nothing in `lib/code_my_spec_web/application.ex`
  or `config/runtime.exs` points `CodeMySpec.EmbedPool` at this module yet, and
  it has never booted a real box. See the design writeup
  (`lib/code_my_spec/embeddings/hetzner_flame_backend_design.md`) for the
  ephemeral-vs-persistent tradeoff this implements one side of, and for the
  prerequisites below in more depth. Read that file and this moduledoc's
  "Known gaps" section before treating this as more than a skeleton.

  ## Why this module never calls `CodeMySpec.Provisioning.Hetzner` directly

  `CodeMySpec.Embeddings` and `CodeMySpec.Provisioning` are both `top_level?:
  true` boundaries, and neither lists the other as a dependency — confirmed
  live against this compiler: a direct call or a bare function capture
  (`&CodeMySpec.Provisioning.Hetzner.create_server/3`) written in this file
  fails `mix compile --warnings-as-errors` with "forbidden reference ...
  references from CodeMySpec.Embeddings to CodeMySpec.Provisioning are not
  allowed". Adding `CodeMySpec.Provisioning` to `Embeddings`' own deps list
  was tried and reverted: `Provisioning` already depends on `Files`, and
  `Files` already depends on `Embeddings` — so that edge would have closed a
  brand new cycle, `Embeddings -> Provisioning -> Files -> Embeddings`, which
  `--warnings-as-errors` treats as a build failure just as hard as a forbidden
  reference does.

  So every Hetzner call this backend makes arrives as a plain function value
  — `:create_server` / `:destroy_server` in config — rather than a module
  name. Boundary only traces aliases, calls and captures written in a
  module's own source; a closure built elsewhere and handed in through
  `opts`/`Application.get_env/2` is just data crossing a boundary, the same
  way `{FLAME.Pool, backend: CodeMySpec.Embeddings.OrtexServing, ...}` already
  names an `Embeddings` module from inside `CodeMySpecWeb.Application` today
  with no violation — `test/support/code_my_spec_test_boundary.ex` names this
  exact distinction: "Boundary flags cross-boundary *calls*, not module
  references". Whoever wires this backend up for real (`application.ex`,
  which already depends on `CodeMySpec.Provisioning`) builds the closures
  there — something like:

      alias CodeMySpec.Provisioning.Hetzner
      platform_scope = %CodeMySpec.Users.Scope{}

      create_server: fn name, opts -> Hetzner.create_server(platform_scope, name, opts) end,
      destroy_server: fn id -> Hetzner.delete_server(platform_scope, id) end

  — the empty `%Scope{}` plus `Hetzner.token/1`'s application-config fallback
  is exactly the pattern `test/integration/live_builder_test.exs` already
  exercises for a platform-owned (non-customer) Hetzner call.

  ## Shape: ephemeral, not power-cycled

  One Hetzner server per boot, created fresh in `remote_boot/1` and meant to
  be destroyed when the runner is done — mirrors `FLAME.FlyBackend` and
  `max: N` reads as "up to N fresh boxes in flight," not "N persistent boxes
  to manage." The design writeup lays out the power-cycled alternative (one
  server, powered on/off instead of created/destroyed) and recommends against
  building it first; this module does not implement it.

  ## Known gaps — real, not hypothetical, and nobody should flip this on
  believing otherwise

  1. **Nothing destroys the Hetzner server when the runner is done**, and
     this is not a TODO so much as a discovery: `FLAME.Backend.handle_info/2`
     — where a first draft of this module assumed cleanup would hook in —
     is never called for either of the two events that mean "this runner is
     finished." Read `deps/flame/lib/flame/runner.ex`'s own `handle_info/2`:
     `{_ref, {:remote_shutdown, reason}}` goes straight to `{:stop,
     {:shutdown, reason}, state}`, and the terminator's own `:DOWN` message
     matches `%Runner{terminator: ^pid} -> {:stop, reason, state}` — neither
     clause calls `maybe_backend_handle_info/2`. `FLAME.FlyBackend` needs no
     such hook because Fly machines carry `auto_destroy: true` — the
     *platform* deletes the VM when its init process exits, something this
     module's `remote_boot/1` cannot ask of Hetzner's API because it has no
     such flag. Without it, a box this backend creates sits there, powered
     on, billing, until something else deletes it. `remote_boot/1` destroys
     the box itself on a boot timeout (that path is plain code, not a FLAME
     hook, so it works) — there is no equivalent for "booted fine and ran for
     a while." Two real options, neither built: a periodic sweeper in the
     shape of `CodeMySpec.Provisioning.Builder`'s own
     `reap_orphaned_builders/2` (label the box, delete anything past an idle
     threshold), or a self-destruct call from *inside* the remote node, which
     would need the Hetzner API token shipped to the box — a real credential
     exposure tradeoff the design writeup raises and does not resolve.

  2. **Nothing makes a Hetzner box reachable to the Fly-hosted parent over
     Erlang distribution.** `FLAME.Terminator` dials out
     (`Node.connect(node(parent.pid))`, in `deps/flame/lib/flame/terminator.ex`)
     rather than waiting to be dialed, which is the easy half — but
     `rel/env.sh.eex` only sets `RELEASE_DISTRIBUTION`/`RELEASE_NODE` for two
     cases: `FLY_APP_NAME` present (long name on Fly's 6PN) or a handful of
     CLI release commands (short name, loopback only). There is no third
     branch for "booted as a FLAME runner off Fly" at all — a Hetzner box
     running this release today would fall into the `sname`/loopback branch
     and could never dial out to a different host. `host_env:
     "CMS_FLAME_RUNNER_IP"` below is forward-looking: nothing sets or reads
     that variable yet. Past that, a Hetzner box and a Fly machine are on
     different providers' networks entirely; `Hetzner.ensure_network/3`'s
     private network does not reach Fly's 6PN, so distribution needs either a
     Fly WireGuard peer into the box or a publicly reachable, TLS-secured
     distribution listener — a real design decision, not made here.

  3. **No portable image exists yet.** This app deploys to Fly via Fly's own
     remote builder, publishing to `registry.fly.io`, not anywhere a Hetzner
     box can pull from. "We host our own registry" (John) is not yet backed
     by a build-and-push pipeline for this app's own release, and `:image`
     below (the Docker reference `remote_boot/1` tells the box to `docker
     run`) has no real default — a caller must supply one once that pipeline
     exists.

  Given 1-3, this module is a structurally-faithful skeleton — `init/1`'s
  validation, the `FLAME.Parent` encoding, `remote_spawn_monitor/2` — proven
  against `FLAME.FlyBackend`'s own shape, but `remote_boot/1` cannot
  presently succeed end to end against a real account for reasons that are
  not bugs in this file.

  ## Configuration

  Set via `Application.get_env(:flame, __MODULE__)` or passed directly as
  pool `:backend` opts (the latter wins on a key-by-key basis, matching
  `FLAME.FlyBackend`):

    * `:create_server` — required, `(name :: String.t(), opts :: keyword() ->
      {:ok, map()} | {:error, term()})`. In production this closes over a
      platform `%CodeMySpec.Users.Scope{}` and
      `&CodeMySpec.Provisioning.Hetzner.create_server/3`.
    * `:destroy_server` — required, `(id :: term() -> {:ok, term()} |
      {:error, term()})`.
    * `:server_type` — required, a Hetzner server type (e.g. `"cpx31"`).
    * `:location` — required, a Hetzner location (e.g. `"fsn1"`).
    * `:hetzner_image` — the Hetzner server (OS/snapshot) image booted —
      this is **not** the application's Docker image. Defaults to
      `"ubuntu-24.04"`; a pre-baked snapshot with Docker already installed
      (the same idea as `CodeMySpec.Provisioning.Builder.ensure_builder_image/3`)
      would cut boot latency but does not exist for this purpose yet.
    * `:image` — required, the application's own Docker image reference
      (`registry/repo:tag`) that cloud-init `docker run`s on the box.
    * `:ssh_key_ids` — required by `Hetzner.create_server/3` itself (it
      refuses without one) even though a FLAME runner has no SSH use case;
      pass the platform's existing key id(s).
    * `:network_ids` — optional Hetzner private network id(s) to attach.
    * `:labels` — optional map, merged with this module's own
      `"cms-flame-role" => "embed"` label.
    * `:registry_auth` — optional `%{username: _, password: _}` baked into
      the cloud-init script's `docker login`, for a private registry. Never
      logged — see `cloud_init/2`.
    * `:env` — optional map merged into the runner's env, alongside the
      `FLAME_PARENT`/`PHX_SERVER=false` this module always sets.
    * `:boot_timeout` — ms to wait for the box to boot, pull the image, and
      dial back. Defaults to `120_000` — a Hetzner Cloud server plus a
      `docker pull` is slower than a Fly Machine boot (`FLAME.FlyBackend`
      defaults to 30s), though this has not been timed against a real box.
    * `:name_prefix` — default `"cms-flame-"`.
  """

  @behaviour FLAME.Backend

  alias FLAME.Parent

  require Logger

  @derive {Inspect,
           only: [
             :server_type,
             :location,
             :hetzner_image,
             :image,
             :boot_timeout,
             :runner_id,
             :runner_node_name,
             :name_prefix
           ]}
  defstruct name_prefix: "cms-flame-",
            server_type: nil,
            location: nil,
            hetzner_image: "ubuntu-24.04",
            image: nil,
            ssh_key_ids: nil,
            network_ids: nil,
            labels: %{},
            registry_auth: nil,
            env: %{},
            boot_timeout: 120_000,
            create_server: nil,
            destroy_server: nil,
            parent_ref: nil,
            runner_name: nil,
            runner_id: nil,
            runner_node_name: nil,
            remote_terminator_pid: nil,
            log: false

  @type t :: %__MODULE__{}

  @valid_opts [
    :name_prefix,
    :server_type,
    :location,
    :hetzner_image,
    :image,
    :ssh_key_ids,
    :network_ids,
    :labels,
    :registry_auth,
    :env,
    :boot_timeout,
    :create_server,
    :destroy_server,
    :log,
    :terminator_sup
  ]

  @required [:server_type, :location, :image, :create_server, :destroy_server, :ssh_key_ids]

  # The remote box's own distribution hostname — mirrors `FLY_PRIVATE_IP` in
  # `FLAME.FlyBackend`. Forward-looking: see the moduledoc's gap #2. Nothing
  # sets this on a booted box today, and `rel/env.sh.eex` does not read it.
  @host_env "CMS_FLAME_RUNNER_IP"

  @cms_role_label "cms-flame-role"

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []

    state =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)
      |> then(&struct(__MODULE__, &1))

    for key <- @required do
      if is_nil(Map.get(state, key)) or Map.get(state, key) == [] do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    runner_name = "#{state.name_prefix}#{rand_id(20)}"
    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> Parent.new(self(), __MODULE__, runner_name, @host_env)
      |> Parent.encode()

    env =
      %{"PHX_SERVER" => "false", "FLAME_PARENT" => encoded_parent}
      |> Map.merge(state.env)

    {:ok, %{state | env: env, parent_ref: parent_ref, runner_name: runner_name}}
  end

  @impl true
  def remote_spawn_monitor(%__MODULE__{runner_node_name: node_name}, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown, do: System.stop()

  @impl true
  def remote_boot(%__MODULE__{parent_ref: parent_ref} = state) do
    create_opts = [
      server_type: state.server_type,
      location: state.location,
      image: state.hetzner_image,
      ssh_key_ids: state.ssh_key_ids,
      network_ids: state.network_ids,
      labels: Map.put(state.labels || %{}, @cms_role_label, "embed"),
      user_data: cloud_init(state)
    ]

    case state.create_server.(state.runner_name, create_opts) do
      {:ok, server} -> await_remote_up(state, server_id(server), parent_ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_remote_up(state, runner_id, parent_ref) do
    new_state = %{state | runner_id: runner_id}

    receive do
      {^parent_ref, {:remote_up, remote_terminator_pid}} ->
        {:ok, remote_terminator_pid,
         %{
           new_state
           | remote_terminator_pid: remote_terminator_pid,
             runner_node_name: node(remote_terminator_pid)
         }}
    after
      state.boot_timeout ->
        Logger.error(
          "[#{inspect(__MODULE__)}] #{state.runner_name} did not connect back within " <>
            "#{state.boot_timeout}ms — destroying it"
        )

        # Unlike a successful boot (see the moduledoc's "known gaps" — there
        # is no FLAME hook for that case), this path is plain code: a box
        # that never dialed home is not going to run anything, so there is
        # nothing waiting on it to finish first.
        _ = state.destroy_server.(runner_id)
        {:error, :timeout}
    end
  end

  # Plain cloud-init: pull the image and run it with the env `init/1` built.
  # No Hetzner call and nothing provider-specific — this function is pure
  # string-building, which is what makes it testable without a box.
  #
  # `registry_auth` and every `env` value are shell-quoted and never logged
  # here. `Hetzner.create_server/3`'s own caller already redacts the whole
  # `user_data` field before logging the create payload (see
  # `CodeMySpec.Provisioning.Hetzner.create_in/4`) — this function does not
  # re-rely on that alone, since this string is also the thing a test would
  # most want to print on failure.
  @doc false
  @spec cloud_init(t()) :: String.t()
  def cloud_init(%__MODULE__{} = state) do
    env_flags =
      state.env
      |> Enum.sort()
      |> Enum.map_join(" ", fn {k, v} -> "-e #{shell_quote("#{k}=#{v}")}" end)

    [
      "#!/bin/bash",
      "set -euo pipefail",
      login_line(state.registry_auth, state.image),
      "docker run -d --name #{shell_quote(state.runner_name)} --restart=no #{env_flags} " <>
        shell_quote(state.image)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp login_line(nil, _image), do: ""

  defp login_line(%{username: username, password: password}, image) do
    host = image |> String.split("/") |> hd()

    "printf %s #{shell_quote(password)} | docker login #{shell_quote(host)} " <>
      "--username #{shell_quote(username)} --password-stdin"
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp rand_id(len) do
    len
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, len)
  end
end
