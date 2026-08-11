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

  ## It answers HTTP, and only HTTP

  A test points `:harness_server_url` at this listener, and that setting is the
  whole VM's — including the harness's own `ChannelClient`s, which derive their
  socket URL from it and redial every second for as long as they are alive.
  Their upgrade requests therefore arrive here, and recording them made
  `last_request/0` answer about traffic no test had made — so an upgrade is
  refused, unrecorded, and only counted, by `upgrades/0`.

  The socket is `CmsHarnessTest.FakeServer`'s surface, not this one. Nothing
  here can upgrade a connection, so refusing is also the truth.
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
    # 0 means "the OS assigns one at bind time", and the port is read back off
    # the bound listener. An explicit `:port` still wins, for a test that needs
    # a known one.
    port = Keyword.get(opts, :port, 0)

    reset()

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: __MODULE__, scheme: :http, ip: {127, 0, 0, 1}, port: port},
        restart: :temporary
      )

    ExUnit.Callbacks.on_exit(fn -> stop(pid) end)

    bound_port(pid, port)
  end

  @doc "What the next request should be answered with."
  @spec respond_with(keyword()) :: :ok
  def respond_with(opts) do
    :persistent_term.put({__MODULE__, :response}, Enum.into(opts, response()))
  end

  @doc "Answer the next request as an event stream of these chunks."
  @spec stream([binary()]) :: :ok
  def stream(chunks), do: respond_with(chunks: chunks)

  @doc """
  The last request that arrived, or nil. Headers are a map, downcased by HTTP.

  Websocket upgrades are not requests — see the moduledoc.
  """
  @spec last_request() ::
          %{method: String.t(), path: String.t(), headers: map(), body: binary()} | nil
  def last_request, do: :persistent_term.get({__MODULE__, :request}, nil)

  @doc """
  The last request to `path`, or nil.

  For flows that make more than one call here — the MCP proxy asks the server
  where a working copy is before it forwards anything to it, so "did it
  forward?" is a question about a path, not about whichever call was last.
  """
  @spec last_request_to(String.t()) :: map() | nil
  def last_request_to(path) do
    {__MODULE__, :requests}
    |> :persistent_term.get([])
    |> Enum.filter(&(&1.path == path))
    |> List.last()
  end

  @doc """
  The last request made with `method`, or nil.

  Same reason as `last_request_to/1`, discriminating on the verb instead of the
  path. A test that acts and then reads `last_request/0` is asserting that
  nothing else reached this server in between, which is not something it
  controls: the harness reconnects and retries on its own schedule, and under a
  full-suite load there is more room between the act and the read for one of
  those to land. That shows up as a bare "Assertion with == failed" in a test
  that passes every time it is run on its own.
  """
  @spec last_request_with_method(String.t()) :: map() | nil
  def last_request_with_method(method) do
    {__MODULE__, :requests}
    |> :persistent_term.get([])
    |> Enum.filter(&(&1.method == method))
    |> List.last()
  end

  @doc "How many websocket upgrades were refused, rather than answered as requests."
  @spec upgrades() :: non_neg_integer()
  def upgrades, do: :persistent_term.get({__MODULE__, :upgrades}, 0)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if websocket_upgrade?(conn), do: refuse_upgrade(conn), else: record(conn)
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  # Not this fake's surface, and not any test's request.
  #
  # The harness's channel clients redial `Config.server_url()` every second,
  # and every test here points that at this listener — so a reconnect lands
  # between a test's own request and the assertion that reads it back, and
  # `last_request/0` hands back the upgrade. The failure names a path nobody
  # asked for and passes on rerun, which reads as a bad assertion rather than
  # as a second caller. Counted rather than dropped silently, so a test can
  # wait for one and prove the isolation holds.
  defp refuse_upgrade(conn) do
    :persistent_term.put({__MODULE__, :upgrades}, upgrades() + 1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"this fake speaks HTTP, not websockets"}))
  end

  defp record(conn) do
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
    :persistent_term.put({__MODULE__, :upgrades}, 0)
  end

  # The port the listener actually bound, asked of the listener.
  #
  # This used to pick a port first and hand it to Bandit — originally
  # `Enum.random(4300..4399)`, then a probe socket opened on 0, read, and closed.
  # Both leave a window between choosing and binding, and under three worktrees'
  # suites on one box a narrow window still gets hit. The failure is not a bind
  # error: the request reaches the *other* suite's upstream, so `last_request/0`
  # answers about a call this test never made and the assertion fails on `==`
  # with no hint a second server was involved. That shape cost two framework
  # issues filed and retracted, and three dead-end investigations (0bc611c9).
  #
  # Binding 0 and reading back closes the window rather than narrowing it —
  # there is no interval during which the port is spoken for but not held.
  defp bound_port(_pid, port) when port > 0, do: port

  defp bound_port(pid, 0) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end
