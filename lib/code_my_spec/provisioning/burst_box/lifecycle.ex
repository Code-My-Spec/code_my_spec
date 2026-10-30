defmodule CodeMySpec.Provisioning.BurstBox.Lifecycle do
  @moduledoc """
  The keep-or-delete policy for a persistent burst box (story 877, criteria
  1736/1737).

  A burst box is not an ephemeral `builder-*` box: it is the one long-lived
  Hetzner server an environment's bursty work shares — ours hosts our own
  embedding runners and our own builds, a customer's hosts theirs. Hetzner
  bills by the hour with a one-hour minimum per server, so the only real
  lever for keeping it cheap is not paying for an hour nothing used: check it
  near the end of the billing hour it already owes, and only pay for the next
  one if something is still using it.

  This module is the decision, not the mechanism. Two different callers reach
  it:

    * the eager, happy-path call — `check/3`, invoked by whoever just finished
      a job on the box (a build, an embedding runner), right when they finish,
      so an idle box is freed the moment the last job of the hour ends rather
      than waiting on the next sweep tick;
    * `CodeMySpec.Provisioning.BurstBox.Sweep`, the periodic backstop that
      calls the same `check/3` on every box it finds, independent of whether
      any caller remembered to.

  Neither owns "is it busy" — that is answered differently for a build box
  (a running container) than for an embedding box (a connected FLAME runner),
  and this module has no business knowing either shape. `:busy?` always
  arrives as a caller-supplied `(Scope.t(), map() -> boolean())`, the same
  injection shape `CodeMySpec.Provisioning.Builder` already uses for
  `:create`/`:destroy` — and for the same reason: this is what keeps the
  policy a unit test instead of a drill.

  ## Why the check only fires near the end of the hour, not continuously

  Checking *at all* mid-hour decides nothing: the hour is already paid for
  either way, so deleting at minute 20 does not save anything and only costs
  a cold boot the next time something needs the box. The check exists to
  answer one question — "is this hour about to become a second hour we did
  not need" — and that question only has an answer in the last few minutes of
  the hour.

  `@check_window_minutes` (55) leaves a five-minute margin before the next
  hour is billed, so a delete decided at :55 has room to actually finish
  before the clock rolls — Hetzner's own delete is asynchronous (see
  `CodeMySpec.Provisioning.Hetzner.delete_server/2`), not instantaneous.
  Whatever drives `check/3` on a timer (the sweep, or any future scheduled
  job) must poll more often than that five-minute width or it can step over
  the window entirely and miss a whole hour's decision — `BurstBox.Sweep`'s
  own default interval is well inside it for exactly this reason.

  ## Why this is stateless

  A box checked twice inside the same window (busy both times) just gets
  asked `:busy?` twice and kept twice — wasted work, not a wrong answer.
  Tracking "already decided this hour" would need a label write-back on
  every check, for no behavioural difference: the only thing that matters is
  that the box is not deleted while busy and is deleted before it is not.
  """

  require Logger

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  # Five-minute margin before the next hour is billed. See the moduledoc for
  # why this is not simply "right at the hour" and why anything driving this
  # on a timer must poll more often than the window is wide.
  @check_window_minutes 55

  @doc """
  Whether `created_at`'s box is inside its end-of-billing-hour check window
  at `now` — true from minute 55 of *every* hour since creation, not just the
  first.

  A `now` at or before `created_at` (clock skew, or a caller passing the
  moment of creation itself) reads as "not due" rather than raising or
  wrapping to a bogus large elapsed time.
  """
  @spec due_for_check?(DateTime.t(), DateTime.t()) :: boolean()
  def due_for_check?(%DateTime{} = created_at, %DateTime{} = now) do
    minutes_into_hour(created_at, now) >= @check_window_minutes
  end

  @doc """
  The policy itself, with the busy answer already in hand: keep a busy box,
  delete an idle one. Exposed separately from `check/3` because this is the
  one line worth pinning on its own — everything else is plumbing around it.
  """
  @spec decide(boolean()) :: :keep | :delete
  def decide(busy?), do: if(busy?, do: :keep, else: :delete)

  @doc """
  Run the policy against one box, right now.

  `opts`:

    * `:busy?` — required, `(Scope.t(), map() -> boolean())`. Answered from
      observable state (a running container, a connected runner node), never
      from in-process bookkeeping — the whole point of `BurstBox.Sweep`
      calling this on a timer is to still get a right answer when whatever
      *would* have made the eager call already crashed.
    * `:destroy` — defaults to `&Hetzner.delete_server/2`.
    * `:now` — defaults to `&DateTime.utc_now/0`.
    * `:force?` — checks an owned deploy box immediately after the deploy ends.

  Returns `:not_due` outside the check window (the common case, every call
  that is not near the end of an hour), `:kept` when due and busy, `:deleted`
  on a successful delete, or the delete's own `{:error, reason}` — never
  raised, so a caller firing this after every job loses nothing by not
  wrapping it.
  """
  @spec check(Scope.t(), map(), keyword()) :: :not_due | :kept | :deleted | {:error, term()}
  def check(%Scope{} = scope, server, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    case created_at(server) do
      {:ok, created} ->
        if Keyword.get(opts, :force?, false) or due_for_check?(created, now) do
          busy_fun = Keyword.fetch!(opts, :busy?)
          act(scope, server, busy_fun.(scope, server), opts)
        else
          :not_due
        end

      :error ->
        Logger.warning(
          "[BurstBox.Lifecycle] #{server_name(server)} has no readable creation time — " <>
            "leaving it alone"
        )

        :not_due
    end
  end

  defp act(_scope, _server, true, _opts), do: :kept

  defp act(scope, server, false, opts) do
    destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)

    case destroy.(scope, server_id(server)) do
      {:ok, _} ->
        Logger.info(
          "[BurstBox.Lifecycle] deleting idle box id=#{server_id(server)} name=#{server_name(server)} " <>
            "age_minutes=#{age_minutes(server, opts)}"
        )

        :deleted

      {:error, reason} = error ->
        Logger.error(
          "[BurstBox.Lifecycle] could not delete #{server_name(server)} at the end of its " <>
            "billing hour: #{inspect(reason)}. It is still running and being billed."
        )

        error
    end
  end

  defp age_minutes(server, opts) do
    case created_at(server) do
      {:ok, created} ->
        max(DateTime.diff(Keyword.get(opts, :now, &DateTime.utc_now/0).(), created, :minute), 0)

      :error ->
        :unknown
    end
  end

  defp minutes_into_hour(created_at, now) do
    elapsed = max(DateTime.diff(now, created_at, :second), 0)
    elapsed |> rem(3600) |> div(60)
  end

  defp created_at(server) do
    case DateTime.from_iso8601(to_string(server_created(server) || "")) do
      {:ok, created, _} -> {:ok, created}
      _ -> :error
    end
  end

  defp server_created(%{"created" => created}), do: created
  defp server_created(%{"server" => server}), do: server_created(server)
  defp server_created(_), do: nil

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp server_name(%{"name" => name}), do: name
  defp server_name(%{"server" => %{"name" => name}}), do: name
  defp server_name(_), do: nil
end
