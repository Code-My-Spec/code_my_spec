defmodule CmsHarness.Browser do
  @moduledoc """
  The browser on this machine, as an MCP server — one session per working copy.

  `vibium mcp` runs JSON-RPC over its own stdin and stdout, so this is a
  subprocess rather than a request: no URL, no credential, and it authenticates
  by being on this machine.

  ## One session per copy

  Each `vibium mcp` process launches its own Chrome, so each copy holds its own
  session and never sees another's page. The session is owned by
  `CmsHarness.Browser.Owner` (in the copy's `Project.Supervisor`), which
  serialises connects and closes the session when the copy stops being served.

  Its tools are not carried by the agent: they go into the catalog a script can
  call, with names discovered from this machine's vibium, never declared here.

  A machine with no vibium reports no browser tools — a quiet state, so it is
  logged. See knowledge/harness, "Browser".
  """

  require Logger

  alias CmsHarness.Mcp.Transport

  # What vibium speaks. Proposing a newer version gets no reply at all, not a
  # counter-offer, so `initialize` never completes.
  @protocol_version "2024-11-05"

  @typedoc """
  What a copy's browser offers, asked once per join.

  `names` is the scoping list: which tools an agent may call is read off names.
  `docs` is what each takes, keyed by name — reported with the manifest rather
  than fetched when asked, because the path an agent uses to decide what to call
  is the one that queues behind sibling agents. `status` says why the list is
  what it is: `:absent` for a machine with no vibium, `{:unreachable, reason}`
  for one that has it and could not be reached, `:ready` otherwise. Both of the
  first two report no tools, and only the second is a fault.
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

  In an unlinked, monitored process with a 5s deadline: it is called from the
  channel join, and `Anubis.Client.start_link/1` links to its caller, so a
  crash there would take the join down.

  Not memoised: the session it opens is kept, so a later join asks a session
  that is already up.
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
      # Not a failure, but the quiet one, so say it: vibium ships on npm.
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

  # In the log and in the answer, so it stays distinct from `:absent`.
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

  # `:vibium_executable`: a path; unset finds the binary behind the npm shim
  # (`CmsHarness.Browser.Executable`); `false` means "use no browser here".
  defp executable do
    case Application.get_env(:code_my_spec, :vibium_executable, nil) do
      false -> nil
      nil -> __MODULE__.Executable.find()
      path -> path
    end
  end
end
