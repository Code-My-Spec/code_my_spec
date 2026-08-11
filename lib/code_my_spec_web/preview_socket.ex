defmodule CodeMySpecWeb.PreviewSocket do
  @moduledoc """
  Pipes a preview's LiveView socket through to the app it belongs to.

  Without this a framed app renders once and never connects, which looks like
  a screenshot of a working application — the most misleading thing a preview
  could show, because everything appears fine until Sam clicks.

  Two connections and a process between them: the browser's, accepted by
  Bandit through WebSock, and ours to the container, opened with
  Mint.WebSocket. Frames go straight across in both directions. Nothing is
  interpreted — LiveView's protocol is its own business, and a proxy that
  understood it would be a proxy that could get it wrong.

  Either side closing closes the other. A half-open pipe would leave the
  browser waiting on a socket nobody is serving, which LiveView reports as a
  connection it will keep retrying.
  """

  @behaviour WebSock

  require Logger

  @impl true
  def init({upstream_url, req_headers}) do
    case connect(upstream_url, req_headers) do
      {:ok, conn, websocket, ref, buffered} ->
        state = %{conn: conn, websocket: websocket, ref: ref}
        opening_frames(buffered, state)

      {:error, reason} ->
        Logger.warning("[PreviewSocket] could not reach #{upstream_url}: #{inspect(reason)}")
        {:stop, :normal, nil}
    end
  end

  defp opening_frames([], state), do: {:ok, state}
  defp opening_frames(frames, state), do: {:push, frames, state}

  # From the browser, on to the app.
  @impl true
  def handle_in({data, opcode: opcode}, state) do
    send_upstream(state, {opcode, data})
  end

  # From the app, on to the browser. Mint hands us transport messages; anything
  # it does not recognise belongs to another socket and is left alone.
  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        decode(%{state | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        Logger.warning("[PreviewSocket] upstream died: #{inspect(reason)}")
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Mint.HTTP.close(conn) && :ok
  def terminate(_reason, _state), do: :ok

  defp connect(url, req_headers) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    ws_scheme = if scheme == :https, do: :wss, else: :ws

    # The browser's own headers are carried up, minus the ones that describe
    # this connection. Sec-WebSocket-Key and friends belong to the handshake
    # Bandit already completed; reusing them upstream would claim a handshake
    # that did not happen here.
    headers =
      Enum.reject(req_headers, fn {k, _} ->
        String.downcase(k) in ~w(host connection upgrade sec-websocket-key
                                 sec-websocket-version sec-websocket-extensions)
      end)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, uri.port),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path(uri), headers) do
      await_upgrade(conn, ref)
    end
  end

  defp path(%URI{path: nil}), do: "/"
  defp path(%URI{path: p, query: nil}), do: p
  defp path(%URI{path: p, query: q}), do: p <> "?" <> q

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, headers} | rest]} ->
            finish_upgrade(conn, ref, status, headers, rest)

          {:ok, conn, _partial} ->
            await_upgrade(conn, ref)

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref)
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  # Whatever arrived alongside the handshake response belongs to the app and
  # has to be carried, not dropped. An app that pushes on connect — LiveView
  # does — commonly lands its first frames in the same TCP segment as the 101,
  # and discarding them looked exactly like a socket that connects and then
  # goes quiet: the pane rendered and never moved again.
  defp finish_upgrade(conn, ref, status, headers, rest) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        {websocket, frames} = decode_buffered(websocket, rest)
        {:ok, conn, websocket, ref, frames}

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end

  defp decode_buffered(websocket, responses) do
    responses
    |> Enum.flat_map(fn
      {:data, _ref, data} -> [data]
      _ -> []
    end)
    |> Enum.reduce({websocket, []}, fn data, {ws, acc} ->
      case Mint.WebSocket.decode(ws, data) do
        {:ok, ws, frames} -> {ws, acc ++ Enum.flat_map(frames, &to_websock/1)}
        {:error, ws, _reason} -> {ws, acc}
      end
    end)
  end

  defp send_upstream(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _websocket_or_conn, reason} ->
        Logger.warning("[PreviewSocket] could not forward a frame: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  defp decode(state, responses) do
    frames =
      Enum.flat_map(responses, fn
        {:data, _ref, data} -> [data]
        _ -> []
      end)

    Enum.reduce(frames, {:ok, state}, fn data, acc -> decode_frame(acc, data) end)
  end

  defp decode_frame({:stop, _, _} = stop, _data), do: stop

  defp decode_frame({:ok, state}, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        push = Enum.flat_map(frames, &to_websock/1)

        if Enum.any?(frames, &match?({:close, _, _}, &1)) do
          {:stop, :normal, push, state}
        else
          {:push, push, state}
        end

      {:error, websocket, reason} ->
        Logger.warning("[PreviewSocket] undecodable frame upstream: #{inspect(reason)}")
        {:stop, :normal, %{state | websocket: websocket}}
    end
  end

  defp to_websock({:text, text}), do: [{:text, text}]
  defp to_websock({:binary, binary}), do: [{:binary, binary}]
  defp to_websock(_other), do: []
end
