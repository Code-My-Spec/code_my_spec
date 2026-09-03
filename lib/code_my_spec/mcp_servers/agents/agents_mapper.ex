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
  alias CodeMySpec.WorkingCopies

  # Where the agent runs and where it is recorded are two different facts, and
  # they only ever disagree by accident.
  #
  # `Agents.id_for/2` falls back to the caller's own copy when a named root
  # resolves to no row for this device and project — deliberately, so a checkout
  # that has never joined is not a refusal. But the reply printed the root that
  # was asked for, so a caller who named one checkout and got a row on another
  # was told nothing had gone wrong. QA of story 988 read "Working copy:
  # .../qa_sandbox" off a row pointing at the main checkout. Issue `af85efc7`.
  #
  # Nothing is moved to fix it: the agent runs where it was told, because
  # relocating it would put it in whichever checkout the caller happened to be
  # in. The disagreement is simply no longer hidden — the stop decision and the
  # analyzer alert are both computed from the recorded copy, so a reader needs
  # to know which one that is.
  defp recorded_against(%Agent{working_copy_id: id, working_copy: root})
       when is_binary(id) and is_binary(root) do
    case WorkingCopies.fetch(id) do
      {:ok, %{root: ^root}} -> ""
      {:ok, %{root: recorded}} -> "\n    Recorded against: #{recorded} — analysis and stop " <>
        "decisions for this agent are computed from that copy, not the root above. The root you " <>
        "named has not joined this project from this machine."
      _ -> ""
    end
  end

  defp recorded_against(_agent), do: ""

  @spec started(Agent.t()) :: Response.t()
  def started(%Agent{} = agent) do
    Response.tool()
    |> Response.text("""
    Agent started.

    Agent: #{agent.id}
    Type: #{agent.role}
    Engine: #{agent.engine}
    Provider: #{agent.provider}
    Model: #{agent.model || "the provider's default"}
    Working copy: #{agent.working_copy}#{recorded_against(agent)}
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
    Working copy: #{agent.working_copy}#{recorded_against(agent)}
    Status: #{agent.status}
    """
  end

  @spec stopped(Agent.t()) :: Response.t()
  def stopped(%Agent{} = agent) do
    Response.tool()
    |> Response.text("""
    Agent stopped.

    Agent: #{agent.id}
    Working copy: #{agent.working_copy}#{recorded_against(agent)}
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

  # The checkout the project talks through holds one agent, and it already has
  # one. Written out rather than left to the generic clause, which reported this
  # as `{:main_copy_occupied, "/Users/..."}` — an inspect of an internal tuple,
  # readable only if you already knew the atom was a reason and the string a
  # path.
  def error({:main_copy_occupied, root}, _provider) do
    refuse("""
    Something is already running in this project's main checkout, so nothing
    was started.

    Checkout: #{root}

    That copy holds one agent on purpose — it is the one the project talks
    through, and a second conversation there is indistinguishable from it.
    Stop the agent that is there, or start this one on a different checkout.
    """)
  end

  def error({:unknown_working_copy, id}, _provider) do
    refuse("""
    No working copy #{id} on this project, so no agent was started.

    Working copy id: #{id}

    That id names no checkout this project owns — either a typo or another
    project's copy — and neither is a reason to start somewhere unnamed. Check
    it against list_working_copies, or name the checkout by its root instead;
    a root that has never joined this project is still a valid destination.
    """)
  end

  def error(:not_found, _provider), do: refuse("Agent not found on this project.")

  def error(:missing_active_project, _provider),
    do: refuse("No active project, so there is nothing to start an agent on.")

  # Neutral about which verb failed. Four tools share this clause — start, stop,
  # message and list — and naming one of them sends a reader who was doing
  # another to look in the wrong place. QA hit exactly that: a message whose
  # provider refused was reported as "could not start the agent".
  # Named rather than left to the catch-all. `inspect/1` on the tuple happens to
  # contain the type names, so a test asserting the refusal lists them would
  # pass on a struct dump — which is the shape of unhelpful this project keeps
  # finding.
  def error({:unknown_role, asked, roles}, _provider) do
    refuse("""
    There is no agent type called #{inspect(asked)}, so nothing was started.

    The types are: #{Enum.map_join(roles, ", ", &to_string/1)}.

    Each one runs on whatever provider and model the account chose for it. A
    type that does not exist has no such choice, which is why this refuses
    rather than picking something.
    """)
  end

  def error(:no_provider, _provider) do
    refuse("""
    This account has no connected provider, so no agent was started.

    Connect one and every agent type will start on a sensible default for it —
    nothing has to be configured per type first.
    """)
  end

  def error(reason, _provider), do: refuse("That agent call failed: #{inspect(reason)}")

  defp refuse(text) do
    Response.tool()
    |> Response.error(text)
  end
end
