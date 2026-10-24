defmodule CmsHarness.SopsKeySocket.Handler do
  @moduledoc """
  One connection to the sops key socket, start to close.

  The protocol is one line in, one response out: a connecting client (only
  ever `CmsHarness.Cli.SopsKey`, but nothing here assumes that) sends its
  own `"<pid> <uid>\\n"`, and gets back either `"OK\\n<key>\\n...\\n"` or
  `"ERR <reason>\\n"`, then the connection closes. All the actual
  decision-making is `CmsHarness.SopsKeySocket.respond/2`; this module is
  only the wire format around it.
  """

  use ThousandIsland.Handler

  alias ThousandIsland.Socket

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state), do: {:continue, Map.put(state, :buffer, "")}

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    buffer = state.buffer <> data

    case String.split(buffer, "\n", parts: 2) do
      [line, _rest] -> respond(socket, line, state)
      [_incomplete] -> {:continue, %{state | buffer: buffer}}
    end
  end

  defp respond(socket, line, state) do
    case CmsHarness.SopsKeySocket.respond(line, state.owner_uid) do
      {:ok, keys} -> Socket.send(socket, "OK\n" <> Enum.join(keys, "\n") <> "\n")
      {:error, reason} -> Socket.send(socket, "ERR " <> reason <> "\n")
    end

    {:close, state}
  end
end
