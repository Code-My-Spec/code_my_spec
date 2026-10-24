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
  from whatever was using it. Same shape `CodeMySpec.Provisioning.Builder`'s
  own `reap_orphaned_builders/2` once had for the ephemeral-per-build boxes
  story 877 retired — list by label, judge each, act — applied here to a box
  that is never abandoned the way a `builder-*` box could be (a burst box is
  *supposed* to still be there), only sometimes idle for longer than its
  billing hour warrants.

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

  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.BurstBox.Lifecycle
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  # The label every burst box carries, set at creation by whatever ensures
  # the box exists. Presence, not value, is what marks a server as this
  # sweep's business — a `builder-*` box or an app server carries no such
  # label and is never looked at twice.
  @role_label "cms-burst-role"

  # A bootstrap server whose snapshot poll gave up without a confirmed
  # answer (`Builder.finish_snapshot/8`, story 877/992 follow-on) is left
  # running on purpose rather than destroyed blind — but "on purpose" still
  # needs an end: once it is old enough that any snapshot it could still be
  # mid-write on would itself have long since finished or failed, this sweep
  # reaps it the same way it would have been destroyed on the happy path.
  # Comfortably past the poll's own 20-minute budget plus whatever the
  # bootstrap took before that, and conveniently inside the one Hetzner
  # billing hour it is already paying for either way.
  @bootstrap_max_age_minutes 60

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
  Run one sweep now, synchronously, against every burst box and every
  pending-outcome bootstrap server `scope` can see.

  `opts` is forwarded to `Lifecycle.check/3` as-is for burst boxes (`:busy?`
  required, `:destroy` / `:now` optional there), and reused for bootstrap
  servers where the names overlap (`:destroy`, `:now`) — `:list` overrides
  `Hetzner.list_servers/1`, `:list_images` overrides
  `Hetzner.list_images/2` (used to check whether a bootstrap server's
  snapshot already succeeded), and `:bootstrap_max_age_minutes` overrides
  `@bootstrap_max_age_minutes`, all for a test or a caller with its own
  view.

  Returns one result per box found, in no particular order — for a test or
  a caller that wants to know what happened, not for anything this module
  itself branches on. Burst boxes answer with `Lifecycle.check/3`'s own
  atoms; bootstrap servers answer `:not_due` (still plausibly waiting),
  `:reaped`, or `{:error, term()}`.
  """
  @spec sweep_now(Scope.t(), keyword()) ::
          [:not_due | :kept | :deleted | :reaped | {:error, term()}]
  def sweep_now(%Scope{} = scope, opts \\ []) do
    list = Keyword.get(opts, :list, &Hetzner.list_servers/1)

    case list.(scope) do
      {:ok, servers} ->
        burst = servers |> Enum.filter(&burst_box?/1) |> Enum.map(&safe_check(scope, &1, opts))

        bootstrap =
          servers
          |> Enum.filter(&bootstrap_box?/1)
          |> Enum.map(&safe_reap_bootstrap(scope, &1, opts))

        burst ++ bootstrap

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

  defp safe_reap_bootstrap(scope, server, opts) do
    reap_bootstrap(scope, server, opts)
  rescue
    e ->
      Logger.error(
        "[BurstBox.Sweep] checking bootstrap server #{inspect(server["name"])} raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, e}
  end

  # Reaps a bootstrap server once its snapshot's outcome is no longer in
  # doubt — confirmed either way, never guessed from the server's age alone
  # while that is the only signal: a young server could just as easily be a
  # legitimate attempt still mid-poll, and destroying it is the exact bug
  # `Builder.finish_snapshot/8` was changed to stop doing.
  defp reap_bootstrap(scope, server, opts) do
    architecture = labels(server)[Builder.bootstrap_role_label()]

    cond do
      Builder.burst_box_image_available?(scope, String.to_existing_atom(architecture), opts) ->
        destroy_bootstrap(scope, server, opts, :image_available)

      stale_bootstrap?(server, opts) ->
        destroy_bootstrap(scope, server, opts, :stale)

      true ->
        :not_due
    end
  end

  defp destroy_bootstrap(scope, server, opts, reason) do
    destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)

    case destroy.(scope, server_id(server)) do
      {:ok, _} ->
        Logger.info(
          "[BurstBox.Sweep] reaping bootstrap server #{inspect(server["name"])} (#{reason})"
        )

        :reaped

      {:error, _reason} = error ->
        error
    end
  end

  defp stale_bootstrap?(server, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()
    max_age = Keyword.get(opts, :bootstrap_max_age_minutes, @bootstrap_max_age_minutes)
    cutoff = DateTime.add(now, -max_age * 60, :second)

    case DateTime.from_iso8601(to_string(server["created"] || "")) do
      {:ok, created, _} -> DateTime.compare(created, cutoff) == :lt
      _ -> false
    end
  end

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp burst_box?(server), do: Map.has_key?(labels(server), @role_label)
  defp bootstrap_box?(server), do: Map.has_key?(labels(server), Builder.bootstrap_role_label())

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
