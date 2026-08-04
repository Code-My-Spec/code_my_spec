defmodule CmsHarnessTest.FakeUpstream do
  @moduledoc """
  A CodeMySpec server's `/mcp/harness`, reduced to a socket that answers.

  A real listener on a real port, so the proxy's outbound call is a real HTTP
  request. What is under test is entirely HTTP — which headers are added, which
  are passed through, what happens to a status nobody planned for, whether a
  stream streams — and a stubbed `Req` would assert the shape of a call while
  proving none of it.

  Each test configures the next answer with `respond_with/1` or `stream/1` and
  reads back what arrived with `last_request/0`.
  """

  import Plug.Conn

  @behaviour Plug

  @default %{
    status: 200,
    body: ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}),
    headers: [],
    chunks: nil
  }

  @doc "Start the listener on a free port and return it. Torn down with the test."
  @spec start!() :: pos_integer()
  def start!(opts \\ []) do
    port = Keyword.get_lazy(opts, :port, fn -> Enum.random(4300..4399) end)

    reset()

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: __MODULE__, scheme: :http, ip: {127, 0, 0, 1}, port: port},
        restart: :temporary
      )

    ExUnit.Callbacks.on_exit(fn -> stop(pid) end)

    port
  end

  @doc "What the next request should be answered with."
  @spec respond_with(keyword()) :: :ok
  def respond_with(opts) do
    :persistent_term.put({__MODULE__, :response}, Enum.into(opts, response()))
  end

  @doc "Answer the next request as an event stream of these chunks."
  @spec stream([binary()]) :: :ok
  def stream(chunks), do: respond_with(chunks: chunks)

  @doc "The last request that arrived, or nil. Headers are a map, downcased by HTTP."
  @spec last_request() ::
          %{method: String.t(), path: String.t(), headers: map(), body: binary()} | nil
  def last_request, do: :persistent_term.get({__MODULE__, :request}, nil)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)

    :persistent_term.put(
      {__MODULE__, :request},
      %{
        method: conn.method,
        path: conn.request_path,
        headers: Map.new(conn.req_headers),
        body: body
      }
    )

    respond(conn, response())
  end

  defp respond(conn, %{chunks: chunks} = response) when is_list(chunks) do
    conn = with_headers(conn, response)

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(response.status)
    |> then(fn conn ->
      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = chunk(conn, chunk)
        conn
      end)
    end)
  end

  defp respond(conn, response) do
    conn
    |> with_headers(response)
    |> put_resp_content_type("application/json")
    |> send_resp(response.status, response.body)
  end

  defp with_headers(conn, response) do
    Enum.reduce(response.headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp response, do: :persistent_term.get({__MODULE__, :response}, @default)

  defp reset do
    :persistent_term.put({__MODULE__, :response}, @default)
    :persistent_term.put({__MODULE__, :request}, nil)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end
