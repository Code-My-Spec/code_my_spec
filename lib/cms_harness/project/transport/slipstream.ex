defmodule CmsHarness.Project.Transport.Slipstream do
  @moduledoc """
  The real wire. A pass-through to Slipstream's own `push/5` and `join/3`.

  Nothing here should ever grow logic — anything that decides something belongs
  in `ChannelClient`, where it can be tested.
  """

  @behaviour CmsHarness.Project.Transport

  @impl true
  def push(socket, topic, event, payload, timeout),
    do: Slipstream.push(socket, topic, event, payload, timeout)

  @impl true
  def join(socket, topic, params), do: Slipstream.join(socket, topic, params)

  @impl true
  def disconnect(socket), do: Slipstream.disconnect(socket)

  # Slipstream returns no handle to a connection before it upgrades, but every
  # connection monitors its client, so the caller's monitors name it.
  @impl true
  def abandon(socket) do
    {:monitored_by, monitors} = Process.info(self(), :monitored_by)

    monitors
    |> Enum.filter(&connection?/1)
    |> Enum.each(&DynamicSupervisor.terminate_child(Slipstream.ConnectionSupervisor, &1))

    socket
  end

  defp connection?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        dictionary[:"$initial_call"] == {Slipstream.Connection, :init, 1}

      nil ->
        false
    end
  end

  defp connection?(_port_or_resource), do: false
end
