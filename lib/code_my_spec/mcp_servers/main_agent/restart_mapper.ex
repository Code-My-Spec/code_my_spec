defmodule CodeMySpec.McpServers.MainAgent.RestartMapper do
  @moduledoc """
  What the main agent is told about a restart it asked for.

  Every refusal says what to do instead. A refusal that only says no leaves an
  agent broken and the main agent with nothing to try, which is how a remedy
  that is merely unavailable becomes a fault nobody records.
  """

  alias Anubis.Server.Response

  @spec restarted(map(), String.t()) :: Response.t()
  def restarted(agent, reason) do
    Response.tool()
    |> Response.text("""
    Restarted.

    Agent: #{agent.id}
    Role: #{agent.role}
    Working copy: #{agent.working_copy}
    For: #{reason}

    It comes back on the same row and the same thread, so it keeps what it was
    doing. Check `list_agent_work` in a while — if the same fault is still
    there, restarting is the wrong remedy and saying so is more use than doing
    it again.
    """)
  end

  @spec error(term()) :: Response.t()
  def error(:not_mine) do
    refuse("""
    That is not one of your agents, so it was not restarted.

    You act on the agents of your own project. If what needs restarting is the \
    harness, it is not yours to restart either: it is a shared harness, serving \
    every working copy on that machine and other projects with it, so restarting \
    it kills their in-flight work too. Raise it with `create_issue` and let \
    somebody who can weigh that decide.

    `list_agent_work` has the ids you can use.\
    """)
  end

  def error({:already_tried, count}) do
    refuse("""
    Already tried #{count} times for this, and the agent has not worked since \
    any of them — so it was not restarted again.

    Restarting is not reaching this. It has been raised as an issue; the next \
    move is a fix, not another attempt.\
    """)
  end

  def error(:machinery_faulty) do
    refuse("""
    Not restarted: the fault is underneath this agent, not in it.

    Every agent on this project is on a machine reporting no tools. Restarting \
    one brings it back into the same client, so the attempt costs a turn and \
    changes nothing — and from the outside it looks identical to an agent that \
    is merely slow to recover, which is how this turns into a loop.

    It has been raised as an issue. `check_machinery` has the detail.\
    """)
  end

  def error(:needs_a_reason) do
    refuse("""
    A restart needs a reason.

    It is checked against what has already been tried, so "restarting it" is \
    not one — say what you are restarting it to fix.\
    """)
  end

  def error(reason), do: refuse("Could not restart: #{inspect(reason)}")

  defp refuse(text), do: Response.tool() |> Response.error(text)
end
