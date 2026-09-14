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
    Browser.forget()
    prior = Application.get_env(:code_my_spec, :vibium_executable)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :vibium_executable)
  defp restore(v), do: Application.put_env(:code_my_spec, :vibium_executable, v)

  defp restore_transport(nil), do: Application.delete_env(:code_my_spec, :harness_mcp_transport)
  defp restore_transport(v), do: Application.put_env(:code_my_spec, :harness_mcp_transport, v)

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
    def list_tool_names(_client), do: {:error, "Server capabilities not set"}

    @impl true
    def disconnect(_client), do: :ok
  end

  # The race that poisons a whole harness instance. Two roots join at the same
  # moment, both find no session registered, both connect, and the loser is told
  # the client is already started — by a name one level down from the one
  # `ensure_started/0` guards on.
  defmodule LostTheRace do
    @behaviour CmsHarness.Mcp.Transport

    @impl true
    def connect(_name, _opts) do
      {:error, {:shutdown, {:failed_to_start_child, Anubis.Client, {:already_started, winner()}}}}
    end

    @impl true
    def call(_client, _tool, _args), do: {:ok, %{}}

    @impl true
    def call(_client, _tool, _args, _opts), do: {:ok, %{}}

    @impl true
    def list_tool_names(_client), do: {:ok, ["browser_navigate"]}

    # Guarded on a pid deliberately: the whole claim is that the loser is handed
    # the winner's live client rather than a name that resolves to nothing.
    @impl true
    def list_tools(client) when is_pid(client),
      do: {:ok, [%{"name" => "browser_navigate"}]}

    @impl true
    def disconnect(_client), do: :ok

    # A real, live process, because the point is that the winner's client is
    # there to be used and the loser is handed it.
    def winner, do: Process.whereis(:cms_harness_browser_race_winner)
  end

  describe "a browser already started by whoever joined first" do
    setup do
      {:ok, pid} = Agent.start_link(fn -> :winner end, name: :cms_harness_browser_race_winner)

      prior = Application.get_env(:code_my_spec, :harness_mcp_transport)
      Application.put_env(:code_my_spec, :harness_mcp_transport, LostTheRace)
      Application.put_env(:code_my_spec, :vibium_executable, "/usr/bin/true")
      Browser.forget()

      on_exit(fn ->
        Browser.forget()
        restore_mcp_transport(prior)
      end)

      {:ok, winner: pid}
    end

    test "the loser uses the winner's client rather than reporting no browser" do
      assert Browser.status() == :ready,
             """
             A root that lost the connect race reported #{inspect(Browser.status())}.

             `ask/0` memoises into `:persistent_term`, so one lost race made a
             whole harness instance answer "no browser" for its lifetime — and
             `machine_serves_tools/1` refuses to start an agent on a copy whose
             machine offers nothing. Measured after a promote: three instances
             live, the one that lost reporting zero tools while its siblings
             reported eighty-five.
             """

      assert Browser.tool_names() == ["browser_navigate"],
             "the winner's client answers; the loser only had to be handed it."
    end
  end

  describe "a machine with no browser" do
    setup do
      # An executable that is not there is exactly what `executable/0` answers
      # nil for, which is the `:no_browser` path.
      Application.put_env(:code_my_spec, :vibium_executable, false)
      Browser.forget()
      :ok
    end

    test "offers nothing, and says it is because there is none" do
      assert Browser.tool_names() == []

      assert Browser.status() == :absent,
             "a machine with no vibium answered #{inspect(Browser.status())}. :absent is " <>
               "the one empty answer that is not a failure, and conflating it with " <>
               "unreachable is the bug in the other direction."
    end
  end

  test "status is remembered with the names, not asked again separately" do
    Application.put_env(:code_my_spec, :vibium_executable, false)
    Browser.forget()

    first = Browser.status()
    _ = Browser.tool_names()

    assert Browser.status() == first,
           "asking twice gave two answers, so the status is being recomputed rather " <>
             "than cached with the names it explains. They would drift the moment a " <>
             "browser came up between two calls."
  end

  describe "a machine whose browser will not answer" do
    setup do
      prior = Application.get_env(:code_my_spec, :harness_mcp_transport)

      Application.put_env(
        :code_my_spec,
        :harness_mcp_transport,
        CmsHarness.BrowserStatusTest.Mute
      )

      # A real path, so this is not the no-browser branch wearing a disguise.
      Application.put_env(:code_my_spec, :vibium_executable, "/usr/bin/true")
      Browser.forget()

      on_exit(fn ->
        Browser.forget()
        restore_mcp_transport(prior)
      end)

      :ok
    end

    test "is not the same answer as having none" do
      assert Browser.tool_names() == [],
             "the tool list is the same either way, which is the whole difficulty."

      assert {:unreachable, reason} = Browser.status(),
             "answered #{inspect(Browser.status())}. A browser that is installed and " <>
               "will not answer reported exactly what a machine with no browser " <>
               "reports, which is how an agent came to be recorded with tools that " <>
               "cannot look at a page while nothing said so."

      assert reason =~ "browser",
             "the reason is what makes the state actionable rather than merely " <>
               "distinguishable, and it reaches a person as-is."
    end
  end

  test "forget/0 clears both" do
    Application.put_env(:code_my_spec, :vibium_executable, false)
    Browser.forget()
    _ = Browser.tool_names()

    assert Browser.forget() == :ok
    # Recomputes rather than raising on a cleared cache.
    assert Browser.tool_names() == []
  end

  defp restore_mcp_transport(nil),
    do: Application.delete_env(:code_my_spec, :harness_mcp_transport)

  defp restore_mcp_transport(prior),
    do: Application.put_env(:code_my_spec, :harness_mcp_transport, prior)
end
