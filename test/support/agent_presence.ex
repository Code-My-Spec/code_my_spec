defmodule CodeMySpecTest.AgentPresence do
  @moduledoc """
  Marking an agent's process alive, the way the copy's harness channel does.

  An agent is running when it is present in `CodeMySpec.Agents.Presence`, not
  when its row says so. A test that needs a running agent tracks it here from a
  holder process linked to the caller, so the key leaves when the test ends —
  as it leaves when a channel dies.
  """

  alias CodeMySpec.Agents.Presence

  @doc """
  Track `agent` present until `absent/1` or the caller exits. Returns the agent.
  Already present from this process, it stays as it is.
  """
  @spec present(map()) :: map()
  def present(%{id: id} = agent) do
    case Process.get({__MODULE__, id}) do
      nil -> track(agent)
      _holder -> agent
    end
  end

  defp track(%{id: id, project_id: project_id} = agent) do
    caller = self()

    holder =
      spawn_link(fn ->
        {:ok, _ref} = Presence.track(self(), Presence.topic(project_id), id, %{})
        send(caller, {:tracked, self()})

        receive do
          :absent -> :ok
        end
      end)

    receive do
      {:tracked, ^holder} -> Process.put({__MODULE__, id}, holder)
    after
      5_000 -> raise "agent #{id} was not tracked"
    end

    agent
  end

  @doc "Untrack `agent`, if this process tracked it: its process is no longer alive."
  @spec absent(map()) :: :ok
  def absent(%{id: id, project_id: project_id}) do
    case Process.delete({__MODULE__, id}) do
      nil -> :ok
      holder -> untrack(holder, project_id, id)
    end
  end

  defp untrack(holder, project_id, id) do
    :ok = Presence.untrack(holder, Presence.topic(project_id), id)
    send(holder, :absent)
    :ok
  end
end
