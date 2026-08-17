defmodule CodeMySpecTest.PreviewWsClient do
  @moduledoc """
  A browser's end of the preview socket, minus the browser.

  Story 886's socket criteria are about whether LiveView frames survive the
  proxy in both directions. That needs a genuine WebSocket on a genuine port —
  `Phoenix.ConnTest` never opens one — but it does not need a browser: the
  claim is about frames crossing, and a real client speaking the real
  handshake settles it. Wallaby would answer the same question far more slowly
  and would put a driver in the path of every other spec in the suite.

  Deliberately small. It connects, sends, and reads with a deadline. Anything
  more would be reimplementing `phoenix.js`, which is not what is under test.
  """

  alias Mint.HTTP
  alias Mint.WebSocket

  @enforce_keys [:conn, :websocket, :ref]
  defstruct [:conn, :websocket, :ref]

  @doc """
  Opens a socket to `port`, addressed to `host` — which is how the proxy knows
  whose preview this is, since the Host header is the only thing carrying it.
  """
  @spec connect(pos_integer(), String.t(), String.t()) ::
          {:ok, %__MODULE__{}} | {:error, term()}
  def connect(port, host, path \\ "/live/websocket") do
    with {:ok, conn} <- HTTP.connect(:http, "localhost", port),
         {:ok, conn, ref} <- WebSocket.upgrade(:ws, conn, path, [{"host", host}]) do
      await_upgrade(conn, ref, deadline())
    end
  end

  @doc "Sends a text frame up to the app."
  @spec send_text(%__MODULE__{}, String.t()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def send_text(%__MODULE__{} = client, text) do
    with {:ok, websocket, data} <- WebSocket.encode(client.websocket, {:text, text}),
         {:ok, conn} <- WebSocket.stream_request_body(client.conn, client.ref, data) do
      {:ok, %{client | conn: conn, websocket: websocket}}
    end
  end

  @doc """
  Reads frames until one arrives, or the deadline passes.

  Returns `{:ok, frames, client}`. An empty list means nothing came back in
  time, which is a legitimate answer for the scenarios that assert silence.

  Stops at the *first* batch. Use `recv_until/3` when the assertion is about a
  particular frame — see the note there.
  """
  @spec recv(%__MODULE__{}, timeout()) :: {:ok, [term()], %__MODULE__{}}
  def recv(%__MODULE__{} = client, timeout \\ 2_000) do
    read_frames(client, System.monotonic_time(:millisecond) + timeout, [])
  end

  @doc """
  Reads until `predicate` holds over the frames seen, or the deadline passes.

  `recv/2` returns as soon as *any* frame arrives, which is the wrong wait for
  a caller asserting a *specific* one: whatever the socket delivered first
  comes back and the frame under test may still be in flight. 886/2328 failed
  that way in a full sweep and passed in isolation, because the interleaving
  only changes when the machine is busy — the same shape as 713/6282, where a
  wait covered one of the two things its assertions read.

  Still returns what it has at the deadline, so a scenario asserting silence
  gets the same answer as before.
  """
  @spec recv_until(%__MODULE__{}, (list() -> boolean()), timeout()) ::
          {:ok, [term()], %__MODULE__{}}
  def recv_until(%__MODULE__{} = client, predicate, timeout \\ 2_000)
      when is_function(predicate, 1) do
    read_until(client, System.monotonic_time(:millisecond) + timeout, [], predicate)
  end

  defp read_until(client, deadline, acc, predicate) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case remaining > 0 and not predicate.(acc) do
      false ->
        {:ok, Enum.reverse(acc), client}

      true ->
        receive do
          message ->
            case WebSocket.stream(client.conn, message) do
              {:ok, conn, responses} ->
                {websocket, frames} = decode_all(client.websocket, responses)

                read_until(
                  %{client | conn: conn, websocket: websocket},
                  deadline,
                  frames ++ acc,
                  predicate
                )

              {:error, conn, _reason, _} ->
                {:ok, Enum.reverse(acc), %{client | conn: conn}}
            end
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            {:ok, Enum.reverse(acc), client}
        end
    end
  end

  @doc "Closes the socket."
  @spec close(%__MODULE__{}) :: :ok
  def close(%__MODULE__{conn: conn}), do: HTTP.close(conn) && :ok

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp await_upgrade(conn, ref, deadline) do
    receive do
      message ->
        case WebSocket.stream(conn, message) do
          {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, headers} | _]} ->
            new_socket(conn, ref, status, headers)

          {:ok, conn, _partial} ->
            await_upgrade(conn, ref, deadline)

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :upgrade_timeout}
    end
  end

  defp new_socket(conn, ref, status, headers) do
    case WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, %__MODULE__{conn: conn, websocket: websocket, ref: ref}}

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end

  defp read_frames(client, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)
    collect(client, deadline, acc, remaining > 0 and acc == [])
  end

  defp collect(client, _deadline, acc, false), do: {:ok, Enum.reverse(acc), client}

  defp collect(client, deadline, acc, true) do
    receive do
      message -> decode(client, deadline, acc, message)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:ok, Enum.reverse(acc), client}
    end
  end

  defp decode(client, deadline, acc, message) do
    case WebSocket.stream(client.conn, message) do
      {:ok, conn, responses} ->
        {websocket, frames} = decode_all(client.websocket, responses)
        read_frames(%{client | conn: conn, websocket: websocket}, deadline, frames ++ acc)

      {:error, conn, _reason, _} ->
        {:ok, Enum.reverse(acc), %{client | conn: conn}}

      :unknown ->
        read_frames(client, deadline, acc)
    end
  end

  defp decode_all(websocket, responses) do
    responses
    |> Enum.flat_map(fn
      {:data, _ref, data} -> [data]
      _ -> []
    end)
    |> Enum.reduce({websocket, []}, fn data, {ws, acc} ->
      case WebSocket.decode(ws, data) do
        {:ok, ws, frames} -> {ws, Enum.reverse(frames) ++ acc}
        {:error, ws, _reason} -> {ws, acc}
      end
    end)
  end
end
