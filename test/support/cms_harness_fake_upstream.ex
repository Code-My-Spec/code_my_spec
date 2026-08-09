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
    port = Keyword.get_lazy(opts, :port, &free_port/0)

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

  @doc """
  The last request to `path`, or nil.

  For flows that make more than one call here — the permission proxy raises the
  request over HTTP and then opens a websocket, and `last_request/0` would hand
  back the socket upgrade.
  """
  @spec last_request_to(String.t()) :: map() | nil
  def last_request_to(path) do
    {__MODULE__, :requests}
    |> :persistent_term.get([])
    |> Enum.filter(&(&1.path == path))
    |> List.last()
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)

    request = %{
      method: conn.method,
      path: conn.request_path,
      headers: Map.new(conn.req_headers),
      body: body
    }

    :persistent_term.put({__MODULE__, :request}, request)

    :persistent_term.put(
      {__MODULE__, :requests},
      :persistent_term.get({__MODULE__, :requests}, []) ++ [request]
    )

    # The token exchange is its own route with its own answer, so a test can
    # assert what the proxy forwarded without that assertion being about the
    # exchange that had to happen first.
    if conn.request_path == "/api/sprite/token" do
      :persistent_term.put({__MODULE__, :exchange}, request)
      respond_to_exchange(conn)
    else
      respond(conn, response())
    end
  end

  @doc "What the last token exchange looked like, or nil."
  @spec last_exchange() :: map() | nil
  def last_exchange, do: :persistent_term.get({__MODULE__, :exchange}, nil)

  @doc "How the token exchange should answer: `:ok`, or a status to refuse with."
  @spec exchange_answers(:ok | pos_integer(), keyword()) :: :ok
  def exchange_answers(answer, opts \\ []) do
    :persistent_term.put({__MODULE__, :exchange_answer}, {answer, opts})
  end

  defp respond_to_exchange(conn) do
    case :persistent_term.get({__MODULE__, :exchange_answer}, {:ok, []}) do
      {:ok, opts} ->
        body = %{
          "access_token" => Keyword.get(opts, :token, "exchanged-token"),
          "token_type" => "Bearer",
          "expires_in" => Keyword.get(opts, :expires_in, 43_200)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {status, _opts} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, ~s({"error":"invalid_credential"}))
    end
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
    :persistent_term.put({__MODULE__, :requests}, [])
    :persistent_term.put({__MODULE__, :exchange}, nil)
    :persistent_term.put({__MODULE__, :exchange_answer}, {:ok, []})
  end

  # Let the OS pick, rather than `Enum.random(4300..4399)`.
  #
  # A hundred slots chosen at random collide often enough to matter once two
  # suites run at once, which happens here whenever another working copy is
  # testing at the same time. The failure is not a bind error — it is the
  # request reaching the *other* suite's upstream, so `last_request/0` and
  # `last_exchange/0` answer about a call this test never made, and the
  # assertion fails on `==` with no hint that a second server was involved.
  #
  # Same shape as `Workspaces.free_port/0`: the TOCTOU window between closing
  # and rebinding surfaces as a failed boot, which is loud and immediate.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end
