defmodule CodeMySpec.Embeddings.HetznerFlameBackend do
  @moduledoc """
  A `FLAME.Backend` that bursts `CodeMySpec.EmbedPool` runners onto the one
  persistent Hetzner burst box an environment already has, as a second,
  cheaper compute option alongside `FLAME.FlyBackend` (step 7, 577de9bb;
  reshaped for the shared burst box, story 877).

  **Still not wired up**, and still never booted a real box — see
  "Known gaps" below. What changed from the first draft is the shape: this
  used to create a fresh Hetzner server per runner and destroy it when done,
  mirroring `FLAME.FlyBackend`'s own "`max: N` means up to N fresh boxes."
  That model is gone. The real one, from John directly: *"Every environment
  gets one burst box... Ours, in CodeMySpec's environment, hosts our
  embeddings AND our builds."* One long-lived server, shared across every
  runner this pool ever boots, its own lifecycle managed on a billing-hour
  cadence by `CodeMySpec.Provisioning.BurstBox.Lifecycle` and
  `CodeMySpec.Provisioning.BurstBox.Sweep` — entirely independent of this
  module, which never creates or destroys *the box* at all.

  ## Why this module never calls `CodeMySpec.Provisioning` directly

  `CodeMySpec.Embeddings` and `CodeMySpec.Provisioning` are both `top_level?:
  true` boundaries, and neither lists the other as a dependency — confirmed
  live against this compiler: a direct call or a bare function capture
  written in this file fails `mix compile --warnings-as-errors` with
  "forbidden reference ... references from CodeMySpec.Embeddings to
  CodeMySpec.Provisioning are not allowed". Adding `CodeMySpec.Provisioning`
  to `Embeddings`' own deps list was tried and reverted in the first draft of
  this module: `Provisioning` already depends on `Files`, and `Files`
  already depends on `Embeddings` — so that edge would have closed a brand
  new cycle, `Embeddings -> Provisioning -> Files -> Embeddings`, which
  `--warnings-as-errors` treats as a build failure just as hard as a
  forbidden reference does.

  So every call this backend makes arrives as a plain function value in
  config, never a module name. Boundary only traces aliases, calls and
  captures written in a module's own source; a closure built elsewhere and
  handed in through `opts`/`Application.get_env/2` is just data crossing a
  boundary, the same way `{FLAME.Pool, backend: CodeMySpec.Embeddings.OrtexServing, ...}`
  already names an `Embeddings` module from inside `CodeMySpecWeb.Application`
  today with no violation. Whoever wires this backend up for real
  (`application.ex`, which already depends on `CodeMySpec.Provisioning`)
  builds the three closures there, something like:

      alias CodeMySpec.Provisioning.{BurstBox, Hetzner}
      platform_scope = %CodeMySpec.Users.Scope{}

      ensure_box: fn name -> BurstBox.ensure(platform_scope, name) end,
      start_runner: fn server, runner_name, env ->
        BurstBox.start_runner(platform_scope, server, runner_name, env)
      end,
      stop_runner: fn server, runner_name ->
        BurstBox.stop_runner(platform_scope, server, runner_name)
      end

  `CodeMySpec.Provisioning.BurstBox.ensure/2` (find-or-create the one box)
  and `.start_runner/stop_runner` (SSH onto an already-running box to start
  or kill one release process on it) do not exist yet — see "Known gaps".

  ## Shape: one shared box, many runners on it

  `remote_boot/1` no longer creates a Hetzner server. It asks `:ensure_box`
  for *the* box this environment already has (idempotent — on every call
  but the very first, this just finds what is already running), then asks
  `:start_runner` to bring up one more runner process *on* that box and
  waits for it to dial home, exactly as before. `max: N` on the pool now
  means "up to N runner processes sharing the one box's CPU and memory," not
  "up to N boxes" — a real change in what capacity means, not just in how it
  is provisioned.

  This is also why the box itself is never destroyed from here: `max: 0`
  (every runner idle) still leaves the box running, because the box is not a
  runner's resource, it is the environment's. `BurstBox.Lifecycle.check/3`,
  called by whoever finishes a job and independently by `BurstBox.Sweep` on
  a timer, is what decides whether the box survives to the next billing
  hour — a decision this module has no part in and no opinion on.

  A runner's own end is simpler than the box's: there is no container and no
  Hetzner resource to destroy for an ordinary finish, because a runner here
  is a bare OTP release process on a box that is already up — `system_shutdown/0`
  calling `System.stop()` inside that same remote process ends it, the same
  as it always has. `:stop_runner` is called from exactly one place in this
  module: the boot-timeout path, where a process that never dialed home has
  to be killed by something other than itself.

  ## Known gaps — real, not hypothetical, and nobody should flip this on
  believing otherwise

  1. **`:ensure_box` / `:start_runner` / `:stop_runner` have no real
     implementation anywhere yet.** This module only defines the contract
     each closure must satisfy (see "Configuration" below); building
     `CodeMySpec.Provisioning.BurstBox.ensure/2` and its SSH-based
     start/stop of one release process on an already-running box is not
     part of this change.
  2. **Nothing makes a Hetzner box reachable to the Fly-hosted parent over
     Erlang distribution.** `FLAME.Terminator` dials out
     (`Node.connect(node(parent.pid))`, in `deps/flame/lib/flame/terminator.ex`)
     rather than waiting to be dialed, which is the easy half — but
     `rel/env.sh.eex` only sets `RELEASE_DISTRIBUTION`/`RELEASE_NODE` for two
     cases today: `FLY_APP_NAME` present (long name on Fly's 6PN) or a
     handful of CLI release commands (short name, loopback only). There is
     no third branch for "started as a FLAME runner off Fly" — a release
     process started this way today falls into the `sname`/loopback branch
     and can never dial out to a different host. That branch was not added
     in this change; `host_env: "CMS_FLAME_RUNNER_IP"` below remains
     forward-looking, nothing sets or reads it yet.
  3. **`CodeMySpec.Provisioning.BurstBox.FlyPeering` exists but is not
     applied to anything.** It gives a box a WireGuard peer into Fly's 6PN
     — the network path gap #2 needs once distribution itself is
     configured — but nothing calls `FlyPeering.apply/2` against a real
     box, and it is deliberately not threaded into `:ensure_box` by this
     change: see that module's own moduledoc for why it has to stay
     removable on its own.

  Given 1-3, this module remains a structurally-faithful skeleton —
  `init/1`'s validation, the `FLAME.Parent` encoding, `remote_spawn_monitor/2`
  — proven against `FLAME.FlyBackend`'s own shape, but `remote_boot/1` cannot
  presently succeed end to end against a real account for reasons that are
  not bugs in this file.

  ## Configuration

  Set via `Application.get_env(:flame, __MODULE__)` or passed directly as
  pool `:backend` opts (the latter wins on a key-by-key basis, matching
  `FLAME.FlyBackend`):

    * `:box_name` — required, `String.t()`. The one shared box's name for
      this environment (e.g. `"burst-platform"`) — not generated here, since
      there is exactly one and every runner this backend ever boots asks
      for the same one.
    * `:ensure_box` — required, `(box_name :: String.t() -> {:ok, map()} |
      {:error, term()})`. Finds the box if it is already running, creates
      and snapshot-boots it from the burst-box image
      (`CodeMySpec.Provisioning.Builder.ensure_burst_box_image/3`) if not.
      Called on every `remote_boot/1`, so it must be cheap in the common
      case where the box already exists.
    * `:start_runner` — required, `(server :: map(), runner_name ::
      String.t(), env :: map() -> :ok | {:error, term()})`. Starts one new
      release process on the already-running box named `runner_name`, with
      `env` (carrying `FLAME_PARENT`/`PHX_SERVER=false`, below) in its
      environment. Nothing here is a Docker container — "our own embedding
      jobs ... run as FLAME runners, no container layer needed."
    * `:stop_runner` — required, `(server :: map(), runner_name ::
      String.t() -> :ok | {:error, term()})`. Kills exactly the one runner
      process named `runner_name` on the box, leaving the box and every
      other runner on it untouched. Called only when a runner never dials
      home within `:boot_timeout`.
    * `:env` — optional map merged into the runner's env, alongside the
      `FLAME_PARENT`/`PHX_SERVER=false` this module always sets.
    * `:boot_timeout` — ms to wait for the runner process to start and dial
      back. Defaults to `180_000` — raised from the ephemeral draft's
      `120_000` guess because a shared box under load from other runners is
      at least as slow to schedule a new process on as a cold Hetzner boot
      was to begin with, though neither number has been measured against a
      real box.
    * `:name_prefix` — default `"cms-flame-"`, for the per-runner name (not
      the box's own — see `:box_name`).
  """

  @behaviour FLAME.Backend

  alias FLAME.Parent

  require Logger

  @derive {Inspect,
           only: [
             :box_name,
             :boot_timeout,
             :runner_name,
             :runner_node_name,
             :name_prefix
           ]}
  defstruct name_prefix: "cms-flame-",
            box_name: nil,
            env: %{},
            boot_timeout: 180_000,
            ensure_box: nil,
            start_runner: nil,
            stop_runner: nil,
            parent_ref: nil,
            runner_name: nil,
            server: nil,
            runner_node_name: nil,
            remote_terminator_pid: nil,
            log: false

  @type t :: %__MODULE__{}

  @valid_opts [
    :name_prefix,
    :box_name,
    :env,
    :boot_timeout,
    :ensure_box,
    :start_runner,
    :stop_runner,
    :log,
    :terminator_sup
  ]

  @required [:box_name, :ensure_box, :start_runner, :stop_runner]

  # The remote box's own distribution hostname — mirrors `FLY_PRIVATE_IP` in
  # `FLAME.FlyBackend`. Forward-looking: see the moduledoc's gap #2. Nothing
  # sets this on a booted box today, and `rel/env.sh.eex` does not read it.
  @host_env "CMS_FLAME_RUNNER_IP"

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []

    state =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)
      |> then(&struct(__MODULE__, &1))

    for key <- @required do
      if is_nil(Map.get(state, key)) do
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
    case state.ensure_box.(state.box_name) do
      {:ok, server} ->
        case state.start_runner.(server, state.runner_name, state.env) do
          :ok -> await_remote_up(%{state | server: server}, parent_ref)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_remote_up(state, parent_ref) do
    receive do
      {^parent_ref, {:remote_up, remote_terminator_pid}} ->
        {:ok, remote_terminator_pid,
         %{
           state
           | remote_terminator_pid: remote_terminator_pid,
             runner_node_name: node(remote_terminator_pid)
         }}
    after
      state.boot_timeout ->
        Logger.error(
          "[#{inspect(__MODULE__)}] #{state.runner_name} did not connect back within " <>
            "#{state.boot_timeout}ms — stopping it"
        )

        # Unlike a successful boot (see the moduledoc's "known gaps" — a
        # runner that finishes normally needs no destroy at all, since it is
        # a bare process on a box that stays up regardless), this path is
        # plain code: a runner that never dialed home is not going to run
        # anything, and killing just this one process leaves the shared box
        # and every other runner on it untouched.
        _ = state.stop_runner.(state.server, state.runner_name)
        {:error, :timeout}
    end
  end

  defp rand_id(len) do
    len
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, len)
  end
end
