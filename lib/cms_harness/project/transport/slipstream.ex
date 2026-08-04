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
end
