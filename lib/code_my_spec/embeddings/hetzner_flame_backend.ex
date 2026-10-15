defmodule CodeMySpec.Embeddings.HetznerFlameBackend do
  @moduledoc """
  A `FLAME.Backend` that bursts `CodeMySpec.EmbedPool` runners onto the one
  persistent Hetzner burst box an environment has, as an alternative to
  `FLAME.FlyBackend`. `CodeMySpecWeb.Application` selects it in prod when
  `HETZNER_API_TOKEN` is set.

  ## Shape: one shared box, many runners on it

  `remote_boot/1` never creates a server. It asks `:ensure_box` for the
  environment's box (cheap once it exists), asks `:start_runner` to start one
  more runner process on it, and waits for that runner to dial home. `max: N`
  on the pool means up to N runner processes sharing one box, not N boxes.

  The box is never destroyed from here: it is the environment's resource, and
  `CodeMySpec.Provisioning.BurstBox.Lifecycle` / `BurstBox.Sweep` decide
  whether it survives the billing hour. A runner is a bare release process,
  so an ordinary finish is `system_shutdown/0` (`System.stop()`) on the
  runner itself; `:stop_runner` is called only when a runner never dials home
  within `:boot_timeout`.

  ## Closures, not calls

  `Embeddings` and `Provisioning` are separate top-level boundaries, and a
  dependency between them would close a cycle (`Provisioning -> Files ->
  Embeddings`). So every Provisioning call arrives as a function in config:
  `CodeMySpecWeb.Application.configure_hetzner_flame_backend!/0` builds them
  from `BurstBox.ensure_box/3`, `start_runner/5` and `stop_runner/4` with a
  platform `%Scope{}`.

  ## Configuration

  Set via `Application.get_env(:flame, __MODULE__)` or passed directly as
  pool `:backend` opts (the latter wins on a key-by-key basis, matching
  `FLAME.FlyBackend`):

    * `:box_name` — required, `String.t()`. The one shared box's name for
      this environment; every runner asks for the same one.
    * `:ensure_box` — required, `(box_name :: String.t() -> {:ok, map()} |
      {:error, term()})`. Finds the box if it is running, creates and
      snapshot-boots it from the burst-box image if not. Called on every
      `remote_boot/1`.
    * `:start_runner` — required, `(server :: map(), runner_name ::
      String.t(), env :: map() -> :ok | {:error, term()})`. Starts one release
      process named `runner_name` on the box with `env` (carrying
      `FLAME_PARENT`/`PHX_SERVER=false`). No container layer.
    * `:stop_runner` — required, `(server :: map(), runner_name ::
      String.t() -> :ok | {:error, term()})`. Kills only that runner process.
    * `:env` — optional map merged into the runner's env, alongside the
      `FLAME_PARENT`/`PHX_SERVER=false` this module always sets.
    * `:boot_timeout` — ms to wait for the runner to start and dial back.
      Defaults to `180_000` (not measured against a real box).
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

  # The runner's own distribution address — mirrors `FLY_PRIVATE_IP` in
  # `FLAME.FlyBackend`. `BurstBox` sets it when a Fly peer is configured, and
  # `rel/env.sh.eex` reads it.
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

        # Kills only this runner; the shared box and its other runners stay.
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
