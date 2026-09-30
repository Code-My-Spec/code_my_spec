defmodule CmsHarnessTest.DialogBrowserTransport do
  @moduledoc """
  A browser MCP transport that answers native dialogs the way vibium 26.8 does.

  Measured against the real binary, `mcp --headless`, on a page whose button
  calls `confirm()`:

    * the click that raises the dialog does not return until vibium's own
      `input.performActions` gives up a minute later, and then as an error that
      does not mention a dialog;
    * every later call fails fast with `context is blocked by an open confirm
      dialog`, naming the type but never the text;
    * `browser_dialog_dismiss` clears it and answers `Dialog dismissed`, and
      with nothing open answers `no such alert`.

  Clicking `#confirm` behaves like the first bullet. Clicking `#confirm-slow`
  behaves like a caller whose deadline is shorter than vibium's minute: the
  client gives up first, with the error Anubis gives. No subprocess, no vibium.
  """

  @behaviour CmsHarness.Mcp.Transport

  alias Anubis.MCP.Error

  @impl true
  def connect(name, _opts) do
    with {:ok, _pid} <- Agent.start(fn -> %{dialog: nil, calls: []} end, name: name) do
      {:ok, name}
    end
  end

  @doc "Every tool this client was asked to call, oldest first."
  def calls(client), do: client |> Agent.get(& &1.calls) |> Enum.reverse()

  @impl true
  def call(client, tool, args), do: call(client, tool, args, [])

  @impl true
  def call(client, tool, args, _opts) do
    Agent.get_and_update(client, fn state ->
      {reply, dialog} = answer(tool, args, state.dialog)
      {reply, %{state | dialog: dialog, calls: [tool | state.calls]}}
    end)
  end

  defp answer("browser_dialog_dismiss", _args, nil),
    do: {{:error, "failed to dismiss dialog: BiDi error: no such alert - no such alert"}, nil}

  defp answer("browser_dialog_dismiss", _args, _open), do: {{:ok, "Dialog dismissed"}, nil}

  defp answer(tool, _args, open) when is_binary(open) do
    {{:error,
      "failed to #{tool}: context is blocked by an open #{open} dialog; accept or dismiss " <>
        "it first (dialog.accept / dialog.dismiss, or handle it with an onDialog listener)"},
     open}
  end

  defp answer("browser_click", %{"selector" => "#confirm"}, nil),
    do:
      {{:error,
        "failed to click: timeout waiting for response to input.performActions after 1m0s"},
       "confirm"}

  defp answer("browser_click", %{"selector" => "#confirm-slow"}, nil),
    do: {{:error, Error.transport(:request_timeout, %{})}, "confirm"}

  defp answer("browser_click", %{"selector" => "#missing"}, nil),
    do: {{:error, "failed to click: element not found: #missing"}, nil}

  defp answer("browser_get_url", _args, nil), do: {{:ok, "http://127.0.0.1:4000/page"}, nil}
  defp answer(_tool, _args, nil), do: {{:ok, "done"}, nil}

  @impl true
  def list_tool_names(_client), do: {:ok, ["browser_click", "browser_dialog_dismiss"]}

  @impl true
  def list_tools(_client), do: {:ok, [%{"name" => "browser_click"}]}

  @impl true
  def disconnect(client) do
    case GenServer.whereis(client) do
      pid when is_pid(pid) -> Agent.stop(pid)
      nil -> :ok
    end
  end
end
