defmodule CodeMySpec.McpServers.Agents.AgentsMapper do
  @moduledoc """
  Text replies for the agents tools.

  Labelled lines — `Agent: …`, `Provider: …` — rather than structured content,
  which is the house rule: `Response.text/2` only, because a structured payload
  sitting beside the text makes Claude read the payload and ignore the prose.
  That makes the labelled line the contract, and it is what
  `TaskResponseHelpers.response_field/2` reads.

  Every refusal says which provider it is about. With several providers
  connectable, an unnamed one leaves the reader to work out which of them is
  missing before they can do anything, and the whole reason to refuse early is
  to save someone that.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Providers

  @spec started(Agent.t()) :: Response.t()
  def started(%Agent{} = agent) do
    Response.tool()
    |> Response.text("""
    Agent started.

    Agent: #{agent.id}
    Engine: #{agent.engine}
    Provider: #{agent.provider}
    Working copy: #{agent.working_copy}
    Account: #{agent.account_id}
    Status: #{agent.status}

    Its turns appear in the agent conversation view for this project, the same
    place a Claude Code agent's do.
    """)
  end

  @doc """
  What the agent said back.

  The id is repeated because a reply with no agent on it is unattributable the
  moment more than one is running, which is the normal case on a working copy.
  """
  @spec replied(String.t(), String.t() | :still_working) :: Response.t()
  def replied(agent_id, :still_working) do
    Response.tool()
    |> Response.text("""
    Agent: #{agent_id}

    Delivered. The agent is still working on it — turns can outlast the wait,
    and this one has. It was not interrupted, and there is no need to send the
    instruction again: doing so would put two of them on the same checkout.
    """)
  end

  def replied(agent_id, reply) do
    Response.tool()
    |> Response.text("""
    Agent: #{agent_id}

    #{reply}
    """)
  end

  @spec listing([Agent.t()]) :: Response.t()
  def listing([]) do
    Response.tool()
    |> Response.text("No agents are running on this project.")
  end

  def listing(agents) do
    body = Enum.map_join(agents, "\n\n", &entry/1)

    Response.tool()
    |> Response.text("#{length(agents)} agent(s) running.\n\n#{body}")
  end

  defp entry(%Agent{} = agent) do
    """
    Agent: #{agent.id}
    Engine: #{agent.engine}
    Provider: #{agent.provider}
    Working copy: #{agent.working_copy}
    Status: #{agent.status}
    """
  end

  @spec stopped(Agent.t()) :: Response.t()
  def stopped(%Agent{} = agent) do
    Response.tool()
    |> Response.text("""
    Agent stopped.

    Agent: #{agent.id}
    Working copy: #{agent.working_copy}
    Status: #{agent.status}
    """)
  end

  @spec error(term(), String.t() | nil) :: Response.t()
  def error(:not_connected, provider) do
    refuse("""
    No credential for #{provider}, so no agent was started.

    Provider: #{provider}

    Connect #{provider} first. Starting without one does not fail here — it
    fails on the agent's first model call, minutes later, in a log nobody is
    reading.
    """)
  end

  def error(:reconnect_required, provider) do
    refuse("""
    The credential for #{provider} can no longer be refreshed, so no agent was
    started.

    Provider: #{provider}

    Reconnect #{provider}. This is not the same as never having connected it:
    the grant existed and has since expired or been revoked, and only
    reconnecting restores it.
    """)
  end

  def error(:unknown_provider, provider) do
    refuse("""
    Unknown provider #{inspect(provider)}.

    Known providers: #{Enum.join(Providers.names(), ", ")}
    """)
  end

  def error(:not_found, _provider), do: refuse("Agent not found on this project.")

  def error(:missing_active_project, _provider),
    do: refuse("No active project, so there is nothing to start an agent on.")

  # Neutral about which verb failed. Four tools share this clause — start, stop,
  # message and list — and naming one of them sends a reader who was doing
  # another to look in the wrong place. QA hit exactly that: a message whose
  # provider refused was reported as "could not start the agent".
  def error(reason, _provider), do: refuse("That agent call failed: #{inspect(reason)}")

  defp refuse(text) do
    Response.tool()
    |> Response.error(text)
  end
end
