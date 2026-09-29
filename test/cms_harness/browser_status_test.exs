defmodule CmsHarness.BrowserStatusTest do
  @moduledoc """
  Two machines that report no browser tools, told apart.

  Issue 02b03d04. `machine_tools` had three states and the middle one covered
  two machines: one with no vibium, and one whose vibium is installed and would
  not answer. Both reported `[]`.

  The second is the expensive one. An agent there is recorded with its tools,
  none of which can look at a page, and the only trace was a warning in the
  harness log. It does not fail — it never looks.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Browser

  setup do
    prior = Application.get_env(:code_my_spec, :vibium_executable)
    on_exit(fn -> restore(prior) end)

    root = "/copies/status-#{System.unique_integer([:positive])}"
    start_supervised!({Browser.Owner, root: root})

    %{root: root}
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :vibium_executable)
  defp restore(v), do: Application.put_env(:code_my_spec, :vibium_executable, v)

  # A transport that starts and then says nothing useful — vibium installed and
  # answering `initialize` with silence is the real shape of this, and it is what
  # every agent on this machine hit for an afternoon.
  defmodule Mute do
    @behaviour CmsHarness.Mcp.Transport

    @impl true
    def connect(name, _opts), do: {:ok, name}

    @impl true
    def call(_client, _tool, _args), do: {:error, "Server capabilities not set"}

    @impl true
    def call(_client, _tool, _args, _opts), do: {:error, "Server capabilities not set"}

    @impl true
    def list_tool_names(_client), do: {:error, "Server capabilities not set"}

    @impl true
    def list_tools(_client), do: {:error, "Server capabilities not set"}

    @impl true
    def disconnect(_client), do: :ok
  end

  describe "a machine with no browser" do
    setup do
      # `false` is exactly what `executable/0` answers nil for, which is the
      # `:no_browser` path.
      Application.put_env(:code_my_spec, :vibium_executable, false)
      :ok
    end

    test "offers nothing, and says it is because there is none", %{root: root} do
      assert %{names: [], docs: %{}, status: :absent} = Browser.probe(root),
             ":absent is the one empty answer that is not a failure, and conflating " <>
               "it with unreachable is the bug in the other direction."
    end
  end

  describe "a machine whose browser will not answer" do
    setup do
      prior = Application.get_env(:code_my_spec, :harness_mcp_transport)
      Application.put_env(:code_my_spec, :harness_mcp_transport, Mute)

      # A real path, so this is not the no-browser branch wearing a disguise.
      Application.put_env(:code_my_spec, :vibium_executable, "/usr/bin/true")

      on_exit(fn -> restore_mcp_transport(prior) end)
      :ok
    end

    test "is not the same answer as having none", %{root: root} do
      assert %{names: [], status: {:unreachable, reason}} = Browser.probe(root),
             "a browser that is installed and will not answer reported exactly what a " <>
               "machine with no browser reports."

      assert reason =~ "browser",
             "the reason is what makes the state actionable rather than merely " <>
               "distinguishable, and it reaches a person as-is."
    end
  end

  defp restore_mcp_transport(nil),
    do: Application.delete_env(:code_my_spec, :harness_mcp_transport)

  defp restore_mcp_transport(prior),
    do: Application.put_env(:code_my_spec, :harness_mcp_transport, prior)
end
