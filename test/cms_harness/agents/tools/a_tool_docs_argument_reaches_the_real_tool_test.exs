defmodule CmsHarness.Agents.Tools.AToolDocsArgumentReachesTheRealToolTest do
  @moduledoc """
  253b3b93/328ce14f: `name` (singular) was never recognized by this harness
  tool's own `arguments/1`, and a `names` that was not already a non-empty
  list was silently turned into no arguments at all -- either way the real
  `tool_docs` MCP tool got called with `%{}` and answered with the full
  catalog, with nothing telling the caller its argument was dropped.

  Captures what `arguments/1` actually sends over `Mcp.call`, rather than
  asserting on the real tool's rendered text -- that tool's own behaviour
  (confirmed correct given atom-keyed params, by the existing
  `CodeMode.Docs` tests) is not what this bug was in.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Tools.ToolDocs

  defmodule RecordingTransport do
    @moduledoc false
    @behaviour CmsHarness.Mcp.Transport

    @impl true
    def connect(_name, _opts), do: {:ok, __MODULE__}

    @impl true
    def call(client, tool, args), do: call(client, tool, args, [])

    @impl true
    def call(_client, _tool, args, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:called_with, args})
      {:ok, %{}}
    end

    @impl true
    def list_tool_names(_client), do: {:ok, []}

    @impl true
    def list_tools(_client), do: {:ok, []}

    @impl true
    def disconnect(_client), do: :ok
  end

  setup do
    previous = Application.get_env(:code_my_spec, :harness_mcp_transport)
    Application.put_env(:code_my_spec, :harness_mcp_transport, RecordingTransport)
    :persistent_term.put({RecordingTransport, :test_pid}, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:code_my_spec, :harness_mcp_transport, previous),
        else: Application.delete_env(:code_my_spec, :harness_mcp_transport)
    end)

    %{context: %{mcp_client: RecordingTransport}}
  end

  test "a singular name reaches the real tool, not an empty call", %{context: context} do
    ToolDocs.execute(%{"name" => "get_criterion"}, context)
    assert_received {:called_with, %{"name" => "get_criterion"}}
  end

  test "a proper names list reaches the real tool unchanged", %{context: context} do
    ToolDocs.execute(%{"names" => ["get_story", "list_stories"]}, context)
    assert_received {:called_with, %{"names" => ["get_story", "list_stories"]}}
  end

  test "a names that is not a list still reaches the real tool, to be refused by name", %{
    context: context
  } do
    ToolDocs.execute(%{"names" => "get_criterion"}, context)

    assert_received {:called_with, %{"names" => "get_criterion"}},
                     "the real tool's own schema validation refuses a malformed names " <>
                       "argument by name -- it must see it, not have it silently dropped here"
  end

  test "no arguments at all still sends none", %{context: context} do
    ToolDocs.execute(%{}, context)
    assert_received {:called_with, %{}}
  end

  test "search reaches the real tool too, not just name/names", %{context: context} do
    ToolDocs.execute(%{"search" => "epic"}, context)
    assert_received {:called_with, %{"search" => "epic"}}
  end
end
