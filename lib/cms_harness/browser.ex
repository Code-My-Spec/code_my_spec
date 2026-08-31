defmodule CmsHarness.Browser do
  @moduledoc """
  The browser on this machine, as an MCP server.

  `vibium mcp` runs JSON-RPC over its own stdin and stdout, so this is a
  subprocess rather than a request: no URL, no credential, and it authenticates
  by being on this machine.

  ## Why it is not twenty-nine tools on the agent

  A QA agent's plugin definition grants twenty-nine `mcp__vibium__browser_*`
  tools today, and every one of them is a schema the model reads on every turn
  to be told what a click is. On top of our own ninety-eight that is most of the
  budget spent before the agent has looked at anything.

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

  @session {:global, {__MODULE__, :session}}

  @doc """
  Start the browser's MCP server, or say why not.

  Idempotent: a second call finds the session that is already up, because the
  machine has one browser and starting a second would be a second Chrome.
  """
  @spec ensure_started() :: {:ok, term()} | {:error, term()}
  def ensure_started do
    case executable() do
      nil ->
        {:error, :no_browser}

      path ->
        Transport.impl().connect(@session, command: path, args: ["mcp"])
    end
  end

  @doc """
  What this machine's browser offers, by name.

  `[]` when there is no browser, which is a state rather than a failure — see
  the moduledoc. Names only: the arguments are what `tool_docs` is for, asked
  once, after the agent has decided which one it wants.
  """
  @spec tool_names() :: [String.t()]
  def tool_names do
    with {:ok, client} <- ensure_started(),
         {:ok, names} <- Transport.impl().list_tool_names(client) do
      names
    else
      {:error, :no_browser} ->
        []

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] this machine's browser did not say what it offers " <>
            "(#{inspect(reason)}); agents started here will have no browser tools"
        )

        []
    end
  end

  @doc "Call one of them."
  @spec call(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def call(tool, arguments) do
    with {:ok, client} <- ensure_started() do
      Transport.impl().call(client, tool, arguments)
    end
  end

  # Configurable so a machine that keeps it somewhere unusual is not stuck, and
  # so a test can point at something that is not a browser.
  defp executable do
    Application.get_env(:code_my_spec, :vibium_executable) || System.find_executable("vibium")
  end
end
