defmodule CmsHarness.Browser do
  @moduledoc """
  The browser on this machine, as an MCP server — one session per working copy.

  `vibium mcp` runs JSON-RPC over its own stdin and stdout, so this is a
  subprocess rather than a request: no URL, no credential, and it authenticates
  by being on this machine.

  ## One session per copy

  `vibium mcp` is one process per stdio client, and each launches a Chrome of
  its own. Three concurrent `vibium mcp --headless` processes on this machine,
  navigated to three different pages at once, each reported its own title back
  — so two copies, two QA agents, can each hold a browser without seeing the
  other's page. Calls are routed per copy already: the server pushes
  `tool_call` on that copy's channel.

  The machine-wide `{:global, {CmsHarness.Browser, :session}}` this replaces is
  what every harness boot tripped on. Every copy probes at join, all at once,
  and all but one collided on that single name. `Anubis.Client.start_link/1`
  links its supervisor to the caller, so each loser's probe process was killed
  by the failed start — `{:shutdown, {:failed_to_start_child, Anubis.Client,
  {:already_started, pid}}}` — rather than handed an error it could recover
  from, and the empty answer was then memoised for the whole VM.

  The session is owned by the copy (`CmsHarness.Browser.Owner`, a child of the
  copy's project supervisor): connects for one copy are serialised there, and
  the session is closed when the copy stops being served.

  ## Why it is not twenty-nine tools on the agent

  `vibium mcp` answers `tools/list` with eighty-five tools, and every one of them
  would be a schema the model reads on every turn. So a third-party server is
  mounted the way ours is: its tools go into the catalog a script can call, and
  the agent carries nothing extra for them. The names are discovered rather than
  declared — this machine's vibium answers, not a list written here that would
  drift the first time vibium ships a tool.

  ## Absent is a state, and a quiet one

  A machine with no vibium reports no browser tools, and an agent there is
  computed without them. That is the honest answer and it is nearly invisible: a
  QA agent that cannot look at anything does not fail, it just never looks.
  """

  require Logger

  alias CmsHarness.Mcp.Transport

  # What vibium speaks, and it will not negotiate.
  #
  # Proposing `2025-06-18` — our own server's version, and this client's default
  # — gets **no reply at all** rather than a counter-offer, so `initialize` never
  # completes and every later request is answered "Server capabilities not set".
  # The same request with `2024-11-05` comes back with serverInfo and a tools
  # capability.
  @protocol_version "2024-11-05"

  @typedoc """
  What a copy's browser offers, asked once per join.

  `names` is the scoping list: which tools an agent may call is read off names.
  `docs` is what each takes, keyed by name — reported with the manifest rather
  than fetched when asked, because the path an agent uses to decide what to call
  is the one that queues behind sibling agents (35e5eb59). `status` says why the
  list is what it is: `:absent` for a machine with no vibium,
  `{:unreachable, reason}` for one that has it and could not be reached,
  `:ready` otherwise. Both of the first two report no tools, and only the second
  is a fault (02b03d04).
  """
  @type probe :: %{
          names: [String.t()],
          docs: %{optional(String.t()) => map()},
          status: :ready | :absent | {:unreachable, String.t()}
        }

  @doc "The name one working copy's browser session is registered under."
  @spec session(String.t()) :: GenServer.name()
  def session(root), do: {:via, Registry, {CmsHarness.Registry, {:browser, root}}}

  @doc """
  Start this copy's browser session, or say why not.

  Idempotent: a session that is already up is used. The connect itself runs in
  the copy's `CmsHarness.Browser.Owner`, so a join probing and an agent's first
  call arriving together for one copy start one session rather than colliding.
  """
  @spec ensure_started(String.t()) :: {:ok, GenServer.name()} | {:error, term()}
  def ensure_started(root) do
    case {executable(), GenServer.whereis(session(root))} do
      {nil, _} -> {:error, :no_browser}
      {_path, pid} when is_pid(pid) -> {:ok, session(root)}
      {path, nil} -> __MODULE__.Owner.connect(root, path)
    end
  end

  @doc false
  # Run inside the copy's owner, which is what serialises it.
  @spec connect(String.t(), String.t()) :: {:ok, GenServer.name()} | {:error, term()}
  def connect(root, path) do
    case GenServer.whereis(session(root)) do
      pid when is_pid(pid) ->
        {:ok, session(root)}

      nil ->
        Transport.impl().connect(session(root),
          command: path,
          args: ["mcp"],
          protocol_version: @protocol_version
        )
    end
  end

  @doc "Close this copy's browser session, if it has one."
  @spec disconnect(String.t()) :: :ok
  def disconnect(root), do: Transport.impl().disconnect(session(root))

  @doc """
  Ask this copy's browser what it offers.

  In a process of its own, and bounded. This is called from the channel join —
  the most important thing this harness does — and `Anubis.Client.start_link/1`
  links its supervisor to whoever called it, so a crash in there takes the
  caller down whatever the caller has wrapped itself in. `spawn_monitor`,
  unlinked, with a deadline, is what isolates it.

  Not memoised. The session it opens is kept for the copy's tool calls, so a
  later join asks a session that is already up; and a machine-wide memo is what
  turned one probe that lost into every copy on the machine reporting none.
  """
  @spec probe(String.t()) :: probe()
  def probe(root) do
    {pid, ref} = spawn_monitor(fn -> exit({:asked, ask_now(root)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:asked, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        unreachable(root, "asking the browser what it offers died (#{inspect(reason)})")
    after
      5_000 ->
        Process.exit(pid, :kill)
        unreachable(root, "the browser did not say what it offers within 5s")
    end
  end

  defp ask_now(root) do
    with {:ok, client} <- ensure_started(root),
         {:ok, tools} <- Transport.impl().list_tools(client) do
      %{names: Enum.map(tools, & &1["name"]), docs: docs(tools), status: :ready}
    else
      # The one empty answer that is not a failure — and still worth saying,
      # because it is the quiet one. vibium ships on npm, so there is no formula
      # to depend on and this is where a person finds out instead (ebc5586d).
      {:error, :no_browser} ->
        Logger.info(
          "[CmsHarness] no browser on this machine, so agents started here cannot " <>
            "look at a page. `npm install -g vibium` if they should."
        )

        %{names: [], docs: %{}, status: :absent}

      {:error, reason} ->
        unreachable(root, "the browser did not say what it offers (#{inspect(reason)})")
    end
  rescue
    error ->
      unreachable(root, "asking the browser what it offers raised #{Exception.message(error)}")
  catch
    :exit, reason ->
      unreachable(root, "the browser died while being asked what it offers (#{inspect(reason)})")
  end

  defp docs(tools) do
    Map.new(tools, fn tool ->
      {tool["name"],
       %{
         "description" => tool["description"],
         "input_schema" => tool["inputSchema"] || tool["input_schema"]
       }}
    end)
  end

  # Said once in the log and once in the answer, so the reason travels with the
  # empty list and stays a different answer from a machine with no vibium.
  defp unreachable(root, reason) do
    Logger.warning(
      "[CmsHarness] #{reason} for #{root}; agents started there will have no browser tools"
    )

    %{names: [], docs: %{}, status: {:unreachable, reason}}
  end

  @doc """
  Call one of them on this copy's browser, within the caller's deadline.

  Without a timeout the MCP client applies its own thirty seconds, so a caller
  asking for a minute got thirty seconds from here. `nil` still means that
  default, for a caller that has no opinion.

  If the call leaves a native dialog open, it is dismissed and noted on the
  answer (`CmsHarness.Browser.Dialog`). Notes left for this copy since its last
  call are added too.
  """
  @spec call(String.t(), String.t(), map(), pos_integer() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def call(root, tool, arguments, timeout \\ nil) do
    with {:ok, client} <- ensure_started(root) do
      earlier = __MODULE__.Owner.take_notes(root)

      client
      |> Transport.impl().call(tool, arguments, opts(timeout))
      |> __MODULE__.Dialog.recover(client, root)
      |> __MODULE__.Dialog.annotate(earlier)
    end
  end

  defp opts(nil), do: []
  defp opts(timeout) when is_integer(timeout) and timeout > 0, do: [timeout: timeout]
  defp opts(_other), do: []

  # Configurable so a machine that keeps it somewhere unusual is not stuck, and
  # so a test can point at something that is not a browser.
  # `false` means "there is no browser here", which is different from unset.
  # Unset looks on PATH; `false` is a machine that has one and should not use it
  # — a server, a box where agents must not drive a browser — and it is the only
  # way to reach the `:absent` branch on a machine where vibium is installed,
  # which is every machine a test runs on here. Unset launches the binary behind
  # the npm shim, not the shim (`CmsHarness.Browser.Executable`).
  defp executable do
    case Application.get_env(:code_my_spec, :vibium_executable, nil) do
      false -> nil
      nil -> __MODULE__.Executable.find()
      path -> path
    end
  end
end
