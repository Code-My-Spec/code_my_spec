defmodule CodeMySpec.Permissions do
  @moduledoc """
  Asking a human to approve something an agent cannot decide alone, and applying
  their answer.

  Today that is one thing: tapping out of the autonomous loop. An agent in
  continuous mode cannot clear `session.continuous` itself — that is the point
  of the flag — so it raises a request, a human approves or rejects it on their
  phone, and the decision comes back over a socket and is applied to the
  session.

  ## Why this exists when three modules already did the work

  `TapOut`, `TapOutWaiter` and `PermissionSocket` came first, and callers reached
  straight into them: the `tap_out` MCP tool, both permission controllers, a
  spex and the fixtures bridge — five consumers, every one naming an internal.
  That is the coupling a context removes, and every sibling here
  (`Notifications`, `Sessions`, `Analysis`) already reads that way.

  Delegating rather than reimplementing, deliberately. The behaviour stays in
  the modules that have it and that the existing tests drive; this is an entry
  point, not a second copy. Nothing about tap-out changes by adding it.

  `PermissionSocket` is not exposed. It is a supervised client the application
  starts, not something a caller reaches for. The two controllers naming it
  today should move here when they next change — leaving them alone for now
  keeps this addition to what it claims to be.
  """

  alias CodeMySpec.Permissions.TapOut

  @doc """
  Register a tap-out request on `session`.

  Returns `{:ok, request_id}` immediately — the human's decision arrives later
  and is applied by a waiter, so the agent is never blocked on a person.
  """
  defdelegate request(scope, session), to: TapOut

  @doc """
  Apply a human decision — `:approve` or `:reject` — to a pending request.

  Approval clears `session.continuous`; rejection leaves it set. Either way the
  pending record is marked and the outcome broadcast.
  """
  defdelegate respond(scope, session, request_id, decision), to: TapOut

  @doc "The PubSub topic carrying tap-out requests and decisions."
  defdelegate topic, to: TapOut
end
