defmodule CodeMySpec.Provisioning.BurstBox.Sweep do
  @moduledoc """
  The safety-net backstop for a persistent burst box (story 877, criteria
  1736/1737) — built and ordered first, ahead of
  `CodeMySpec.Provisioning.BurstBox.Lifecycle`, because it is the piece that
  has to exist no matter how the policy above it changes.

  FLAME gives a backend no hook for "this runner finished normally": read
  `deps/flame/lib/flame/runner.ex`'s own `handle_info/2` — both ways a runner
  ends (`{:remote_shutdown, _}` and the terminator's own `:DOWN`) go straight
  to `{:stop, reason, state}` inside `Runner` itself, never through
  `maybe_backend_handle_info/2`. A build dying before it reaches its own
  cleanup call is the same shape of gap from the other workload. So nothing
  about a finished job can be trusted to always ask whether the box it ran on
  should go — the eager, happy-path call into `Lifecycle.check/3` is a real
  optimization (free the box the instant the last job of the hour ends) but
  never the only path, because the thing that would have made that call is
  exactly the thing that might have crashed.

  This is the other path: list every box this process knows how to find, and
  ask the same policy about each of them, on a timer, needing no cooperation
  from whatever was using it. Same shape as
  `CodeMySpec.Provisioning.Builder`'s own `reap_orphaned_builders/2` — list by
  label, judge each, act — applied to a box that is never abandoned the way a
  `builder-*` box is (a burst box is *supposed* to still be there), only
  sometimes idle for longer than its billing hour warrants.

  ## What this does not solve

  A `:busy?` closure that itself raises, hangs, or answers wrong is not
  something this module can detect — `sweep_now/2` rescues around each box so
  one bad answer does not take the whole sweep (or the GenServer driving it)
  down, but "rescued and logged" is not "correct," and there is no second
  signal here to cross-check a wrong `:busy?` against. A caller whose busy
  check can itself be lied to by the same crash that would have skipped the
  eager call is a real gap this task leaves open — see the field report for
  what observable state each workload's `:busy?` should be built from.
  """

  use GenServer

  require Logger

  alias CodeMySpec.Provisioning.BurstBox.Lifecycle
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  # The label every burst box carries, set at creation by whatever ensures
  # the box exists. Presence, not value, is what marks a server as this
  # sweep's business — a `builder-*` box or an app server carries no such
  # label and is never looked at twice.
  @role_label "cms-burst-role"

  # Anonymous unless a caller asks for a name. A customer's own sweep and the
  # platform's own are two different `Scope`s with no business sharing one
  # process, let alone one registered name — `:name` stays opt-in rather than
  # defaulting to this module, which would let only one ever run at a time.
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The label this sweep looks for to recognise a managed burst box."
  @spec role_label() :: String.t()
  def role_label, do: @role_label

  @doc """
  Run one sweep now, synchronously, against every burst box `scope` can see.

  `opts` is forwarded to `Lifecycle.check/3` as-is (`:busy?` required,
  `:destroy` / `:now` optional there). `:list` overrides
  `Hetzner.list_servers/1` for a test or a caller with its own view.

  Returns one `Lifecycle.check/3` result per burst box found, in no
  particular order — for a test or a caller that wants to know what
  happened, not for anything this module itself branches on.
  """
  @spec sweep_now(Scope.t(), keyword()) :: [:not_due | :kept | :deleted | {:error, term()}]
  def sweep_now(%Scope{} = scope, opts \\ []) do
    list = Keyword.get(opts, :list, &Hetzner.list_servers/1)

    case list.(scope) do
      {:ok, servers} ->
        servers
        |> Enum.filter(&burst_box?/1)
        |> Enum.map(&safe_check(scope, &1, opts))

      {:error, reason} ->
        Logger.error("[BurstBox.Sweep] could not list servers: #{inspect(reason)}")
        []
    end
  end

  # One box's own failure — raised from `:busy?`, from `:destroy`, from
  # anything injected — must not cost every other box its check this tick.
  # See the moduledoc's "what this does not solve": this is the rescue that
  # keeps the sweep itself alive, not a claim that the answer underneath it
  # was right.
  defp safe_check(scope, server, opts) do
    Lifecycle.check(scope, server, opts)
  rescue
    e ->
      Logger.error(
        "[BurstBox.Sweep] checking #{inspect(server["name"])} raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, e}
  end

  defp burst_box?(server), do: Map.has_key?(labels(server), @role_label)

  defp labels(%{"labels" => labels}) when is_map(labels), do: labels
  defp labels(%{"server" => server}), do: labels(server)
  defp labels(_), do: %{}

  @impl GenServer
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    interval_ms = Keyword.get(opts, :interval_ms, :timer.minutes(2))

    schedule(interval_ms)
    {:ok, %{scope: scope, interval_ms: interval_ms, opts: opts}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep_now(state.scope, state.opts)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)
end
