defmodule CodeMySpec.Auth.WebSocketBackoff do
  @moduledoc """
  Exponential backoff with jitter for the long-lived Slipstream socket clients
  (`ProjectsSocket`, `IssuesSocket`).

  When the server is unreachable (e.g. Cloudflare 502s), an immediate-reconnect
  loop hammers the origin. `delay/1` computes a capped, jittered wait based on
  the number of consecutive failed attempts so reconnection backs off instead.

  Uses "equal jitter": the delay is uniformly distributed in the top half of the
  capped window, i.e. `[capped/2, capped]`. This keeps a floor (we never busy
  loop) while spreading attempts so the two sockets don't reconnect in lockstep.
  """

  @base_ms 1_000
  @cap_ms 10_000

  @doc """
  Backoff delay in milliseconds for the given (zero-based) attempt count.

  Attempt 0 → ~1s, doubling each attempt, capped at #{@cap_ms}ms.
  """
  @spec delay(non_neg_integer()) :: pos_integer()
  def delay(attempts) when is_integer(attempts) and attempts >= 0 do
    capped = min(@cap_ms, @base_ms * Integer.pow(2, min(attempts, 16)))
    half = div(capped, 2)
    half + :rand.uniform(half)
  end
end
