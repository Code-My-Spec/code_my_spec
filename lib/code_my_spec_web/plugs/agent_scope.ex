defmodule CodeMySpecWeb.Plugs.AgentScope do
  @moduledoc """
  Which agent is making this MCP call, from `X-Agent-Id`.

  The identity an agent should not have to state. Five lifecycle tools need to
  know who is calling — `start_task`, `evaluate_task`, `cancel_task`,
  `list_tasks`, `tap_out` — and until now the only answer available was a
  `session_id` injected by the session-start hook. An agent we run fires no
  hooks, so nothing injected one, and its own id is not in its prompt: it could
  take turns and use tools and not claim a task. John: *"it shouldn't need its
  own ID to start tasks and stuff like that. That should be implicit and
  included in its calls."*

  So it rides on the connection, the way the working copy already does. An agent
  inside our own BEAM still reaches the server over HTTP — `server_url` is a
  real URL, on Fly in production — so nothing about the caller is ambient.

  ## Authoritative, because we mint it

  The value is the server's own: `Agents.start_agent/2` inserts the row, sends
  the id over the channel to start it, and the harness hands it back here. John:
  *"we can make it authoritative because we are applying the agent ID
  deterministically."*

  ## Checked anyway

  Deterministic on our side does not make the header trustworthy on the wire —
  it is a claim, exactly as `X-Harness-Id` is, and this pipeline authenticates
  the *caller* rather than the agent. So the agent is resolved within the
  project the request is already scoped to, and one belonging to another project
  is dropped rather than honoured. A header that could name any agent anywhere
  would let one harness act as another's.

  Dropped rather than refused: a call that names no agent, or names one it may
  not have, is a call without an agent — and the tools that need one say so in
  their own words. Refusing here would take down every call on the connection,
  including the ninety-odd that never wanted an agent.
  """

  import Plug.Conn

  alias CodeMySpec.Agents

  def init(opts), do: opts

  def call(conn, _opts) do
    with agent_id when is_binary(agent_id) <- header(conn, "x-agent-id"),
         %{} = scope <- conn.assigns[:current_scope],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id) do
      assign(conn, :agent_id, agent.id)
    else
      _ -> conn
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end
end
