defmodule CodeMySpec.McpServers.NoToolTakesABareIdTest do
  @moduledoc """
  A tool names its key after its entity: `persona_id`, `component_id`,
  `notification_id`. Agents that learned a bare `id` from one tool passed it
  to `get_issue`, which takes `issue_id` — 68 times across 14 agents.

  Walks every server's registrations rather than a list written here, so a new
  server or tool is covered without touching this file.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}

  defp servers do
    {:ok, modules} = :application.get_key(:code_my_spec, :modules)

    Enum.filter(modules, fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :__components__, 1)
    end)
  end

  defp fields(tool) do
    tool.input_schema
    |> Map.get("properties", Map.get(tool.input_schema, :properties, %{}))
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  test "the servers are found and their fields read" do
    assert LocalServer in servers()
    assert ScriptableTools in servers()

    get_issue = Enum.find(ScriptableTools.registrations(), &(&1.name == "get_issue"))

    assert "issue_id" in fields(get_issue)
  end

  test "no registered tool declares a field named id" do
    offenders =
      for server <- servers(),
          tool <- server.__components__(:tool),
          "id" in fields(tool),
          uniq: true,
          do: "#{tool.name} (#{inspect(tool.handler)})"

    assert offenders == [],
           "name the key after its entity instead of `id`: #{Enum.join(offenders, ", ")}"
  end
end
