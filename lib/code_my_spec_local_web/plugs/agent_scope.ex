defmodule CodeMySpecLocalWeb.Plugs.AgentScope do
  @moduledoc """
  Which agent is making this MCP call, from `X-Agent-Id`.

  The local endpoint's half of `CodeMySpecWeb.Plugs.AgentScope`. Same rule, same
  reasoning — read that one for the doctrine; it is the original and this is
  deliberately identical to it rather than a variation. Two modules because
  `CodeMySpecLocalWeb` and `CodeMySpecWeb` are sibling top-level boundaries and
  neither may reach into the other.

  ## Why this existed only on the hosted side, and what that cost

  QA of story 1016 found it. The hosted `:mcp_protected` pipeline carries
  `AgentScope`; the local `:mcp` pipeline carried `LocalOnly` and `HarnessScope`
  and nothing else. So on `:4004` — the endpoint every locally-run agent
  actually calls — `frame.assigns[:agent_id]` was always absent.

  `ask_user_question` reads it to decide who holds the question. With no agent
  it wrote `agent_id NULL` and `holder = "user"`, which means **every question a
  local agent asked went straight to the person**, bypassing the main agent that
  exists to answer it. Worse, `QuestionsRepository` inner-joins on `agent_id`, so
  those rows are invisible to `list_open_questions` and unreachable by
  `answer_question` — the main agent could not have intercepted them even if it
  had known.

  That is stories 1053, 1058 and 1060's whole premise inoperative on the local
  endpoint, with no symptom on either side: the user sees questions and assumes
  the main agent judged them not worth answering; the main agent sees an empty
  list and assumes nobody is blocked.

  ## Ordering

  After `HarnessScope`, which is what puts `current_scope` on the conn. The
  agent is resolved *within* the project the request is already scoped to, so a
  header naming another project's agent is dropped rather than honoured.

  Dropped rather than refused, as on the hosted side: a call that names no agent
  is a call without an agent, and the tools that need one say so themselves.
  Refusing here would take down every call on the connection, including the
  ninety-odd that never wanted an agent.
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
