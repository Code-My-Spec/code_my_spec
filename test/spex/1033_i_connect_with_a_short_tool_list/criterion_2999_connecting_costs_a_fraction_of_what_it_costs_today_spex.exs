defmodule CodeMySpecSpex.Story1033.Criterion2999Spex do
  @moduledoc """
  Story 1033 — I connect with a short tool list
  Criterion 2999 — Connecting costs a fraction of what it costs today

  The number the story exists to change: 111 tools and 82,591 bytes, measured
  against the running harness on 2026-08-28, paid by every agent at connect for
  a task that calls three or four of them.

  Asserted on the payload an agent is actually handed, not on a count — a
  server could advertise fifteen enormous tools and satisfy a count while
  costing the same.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I connect with a short tool list" do
    scenario "Connecting costs a fraction of what it costs today" do
      given_ "the harness registers its full complement of tools", context do
        # given: already true — the registrations are compile-time `component/1`
        # declarations on the two server modules, so there is nothing to drive.
        # Asserted rather than assumed because the saving below is only
        # meaningful against the whole surface.
        total = length(LocalServer.__components__()) + length(ScriptableTools.__components__())

        assert total > 100, "expected the whole tool surface, found #{total}"

        {:ok, context}
      end

      when_ "an agent connects and reads the tool list", context do
        payload =
          LocalServer.__components__()
          |> Enum.map(
            &%{name: &1.name, description: &1.description, inputSchema: &1.input_schema}
          )
          |> Jason.encode!()

        {:ok, Map.put(context, :payload, payload)}
      end

      then_ "it receives the workflow spine and code mode", context do
        names = MapSet.new(LocalServer.__components__(), & &1.name)

        assert "get_next_requirement" in names
        assert "start_task" in names
        assert "run_script" in names
        assert "tool_docs" in names
        {:ok, context}
      end

      then_ "and the list costs a fraction of the 82,591 bytes it did", context do
        assert byte_size(context.payload) < 82_591 / 4,
               "the list is #{byte_size(context.payload)} bytes; the story is about an " <>
                 "order-of-magnitude change, not a trim"

        {:ok, context}
      end
    end
  end
end
