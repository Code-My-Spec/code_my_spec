defmodule CmsHarness.Browser do
  @moduledoc """
  The browser on this machine, as an MCP server.

  `vibium mcp` runs JSON-RPC over its own stdin and stdout, so this is a
  subprocess rather than a request: no URL, no credential, and it authenticates
  by being on this machine.

  ## Why it is not twenty-nine tools on the agent

  `vibium mcp` answers `tools/list` with eighty-five tools, and every one of them
  would be a schema the model reads on every turn to be told what a click is. On
  top of our own ninety-eight that is most of the budget spent before the agent
  has looked at anything.

  Not twenty-nine, which is what `plugins/claude/agents/qa.md` grants a QA agent
  — a number I once mistook for this one. The plugin's grant is a subset of what
  the browser has, and the tools it leaves out cost the same to carry.

  So a third-party server is mounted the way ours is: its tools go into the
  catalog a script can call, and the agent carries nothing extra for them. The
  names are discovered rather than declared — this machine's vibium answers, not
  a list written here that would drift the first time vibium ships a tool.

  ## Absent is a state, and a quiet one

  A machine with no vibium reports no browser tools, and an agent there is
  computed without them. That is the honest answer and it is nearly invisible: a
  QA agent that cannot look at anything does not fail, it just never looks.
  Making vibium an install prerequisite is what turns that into something the
  install would have said — issue `ebc5586d`.
  """

  require Logger

  alias CmsHarness.Mcp.Transport

  # What vibium speaks, and it will not negotiate.
  #
  # Proposing `2025-06-18` — our own server's version, and this client's default
  # — gets **no reply at all** rather than a counter-offer, so `initialize` never
  # completes and every later request is answered "Server capabilities not set".
  # Verified by hand: the same request with `2024-11-05` comes back with
  # serverInfo and a tools capability, and with the newer one comes back empty.
  #
  # That silence is vibium's bug rather than ours — the protocol has a server
  # answer with a version it *does* support — but it is not one we can fix from
  # here, and every agent on a machine with a browser was getting no browser
  # tools because of it.
  @protocol_version "2024-11-05"

  @session {:global, {__MODULE__, :session}}
  @cached {__MODULE__, :tool_names}

  @doc """
  Start the browser's MCP server, or say why not.

  Idempotent: a second call finds the session that is already up, because the
  machine has one browser and starting a second would be a second Chrome.
  """
  @spec ensure_started() :: {:ok, term()} | {:error, term()}
  def ensure_started do
    case {executable(), whereis()} do
      {nil, _} ->
        {:error, :no_browser}

      # Already up. This claimed to be idempotent and was not: it called
      # `connect` unconditionally, and the second call failed on
      # `:already_started` — so the *second* agent to ask on a machine got no
      # browser tools and a log line about a child that could not start.
      {_path, session} when session != nil ->
        {:ok, @session}

      {path, nil} ->
        Transport.impl().connect(@session,
          command: path,
          args: ["mcp"],
          protocol_version: @protocol_version
        )
    end
  end

  defp whereis, do: GenServer.whereis(@session)

  @doc """
  What this machine's browser offers, by name.

  `[]` when there is no browser, which is a state rather than a failure — see
  the moduledoc. Names only: the arguments are what `tool_docs` is for, asked
  once, after the agent has decided which one it wants.
  """
  @spec tool_names() :: [String.t()]
  def tool_names do
    {names, _status} = asked()
    names
  end

  @doc """
  Why this machine offers the tools it does.

  `:absent` for a machine with no vibium, `{:unreachable, reason}` for one that
  has it and could not be reached, `:ready` otherwise. The distinction is the
  whole point: both of the first two report no tools, and treating them as one
  state is how a QA agent that could not look at anything looked exactly like a
  QA agent on a machine that was never meant to.
  """
  @spec status() :: :ready | :absent | {:unreachable, String.t()}
  def status do
    {_names, status} = asked()
    status
  end

  defp asked do
    case :persistent_term.get(@cached, :unasked) do
      :unasked ->
        {names, status} = ask()
        :persistent_term.put(@cached, {names, status})
        {names, status}

      cached ->
        cached
    end
  end

  # Asked once per harness, in a process of its own, and bounded.
  #
  # This is called from the channel join — the most important thing this harness
  # does — and the first version started a subprocess there and let the failure
  # through. It cost two crash loops in a row: first `Anubis.Client` raising on
  # a via-name with no explicit transport name, then `list_tools` addressed at
  # the supervisor `start_link/1` returns instead of at the client.
  #
  # `rescue` was not enough for either, and that is the lesson rather than the
  # bug: `Anubis.Client.start_link/1` links its supervisor to whoever called it,
  # so a crash in there takes the caller down whatever the caller has wrapped
  # itself in. The only thing that actually isolates it is not being the same
  # process — hence `spawn_monitor`, unlinked, with a deadline.
  #
  # Memoised on top, because what a machine has installed does not change
  # between two joins a second apart.
  defp ask do
    {pid, ref} = spawn_monitor(fn -> exit({:asked, ask_now()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:asked, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        unreachable("asking this machine's browser what it offers died (#{inspect(reason)})")
    after
      5_000 ->
        Process.exit(pid, :kill)
        unreachable("this machine's browser did not say what it offers within 5s")
    end
  end

  defp ask_now do
    with {:ok, client} <- ensure_started(),
         {:ok, names} <- Transport.impl().list_tool_names(client) do
      {names, :ready}
    else
      # The one empty answer that is not a failure — and still worth saying once,
      # because it is the quiet one. An agent here does not fail for want of a
      # browser; it never looks at anything, and until this line the machine said
      # nothing at all about it. Issue ebc5586d wanted a package prerequisite;
      # vibium ships on npm, so there is no formula to depend on and this is
      # where a person finds out instead.
      {:error, :no_browser} ->
        Logger.info(
          "[CmsHarness] no browser on this machine, so agents started here cannot " <>
            "look at a page. `npm install -g vibium` if they should."
        )

        {[], :absent}

      {:error, reason} ->
        unreachable("this machine's browser did not say what it offers (#{inspect(reason)})")
    end
  rescue
    error ->
      unreachable(
        "asking this machine's browser what it offers raised #{Exception.message(error)}"
      )
  catch
    :exit, reason ->
      unreachable(
        "this machine's browser died while being asked what it offers (#{inspect(reason)})"
      )
  end

  # A browser that is installed and cannot be reached, said once in the log and
  # once in the answer.
  #
  # The log line existed already and was the only record, which is what made
  # this expensive: a QA agent was recorded with twenty-nine tools, none of them
  # could look at a page, and the sole trace was a warning nobody reads. It does
  # not fail; it never looks. So the reason travels with the empty list now, and
  # `{[], :absent}` — a machine that simply has no vibium — stays a different
  # answer from this one.
  defp unreachable(reason) do
    Logger.warning("[CmsHarness] #{reason}; agents started here will have no browser tools")
    {[], {:unreachable, reason}}
  end

  @doc "Ask again — for a machine that installed a browser since it came up."
  @spec forget() :: :ok
  def forget, do: :persistent_term.erase(@cached) && :ok

  @doc "Call one of them."
  @spec call(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def call(tool, arguments) do
    with {:ok, client} <- ensure_started() do
      Transport.impl().call(client, tool, arguments)
    end
  end

  # Configurable so a machine that keeps it somewhere unusual is not stuck, and
  # so a test can point at something that is not a browser.
  # `false` means "there is no browser here", which is different from unset.
  # Unset looks on PATH; `false` is a machine that has one and should not use it
  # — a server, a box where agents must not drive a browser — and it is the only
  # way to reach the `:absent` branch on a machine where vibium is installed,
  # which is every machine a test runs on here.
  defp executable do
    case Application.get_env(:code_my_spec, :vibium_executable, nil) do
      false -> nil
      nil -> System.find_executable("vibium")
      path -> path
    end
  end
end
