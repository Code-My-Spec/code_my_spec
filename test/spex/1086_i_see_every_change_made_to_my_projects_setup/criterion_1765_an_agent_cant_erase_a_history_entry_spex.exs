defmodule CodeMySpecSpex.Story1086.Criterion1765Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1765 — An agent can't erase a history entry.

  Append-only is a property of the published surface, not a permission
  check on it: `CodeMySpec.Activity` exports `record/4,5`, `list_for_project/1,2`
  and `list_for_resource/2` and nothing else — there is no `delete`, no
  `update`, no MCP tool or LiveView event that reaches one. An agent
  cannot be refused an erase it has no way to attempt in the first place,
  which is the stronger guarantee: a refusal only proves today's check
  caught today's attempt.

  Surface: `CodeMySpec.Activity`.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An agent can't erase a history entry", criterion: 1765 do
    scenario "the module that owns the log exposes no way to erase from it" do
      given_ "an entry already in the log", context do
        {:ok, entry} =
          CodeMySpec.Activity.record(context.scope, "provision", "servers", "ran the server step")

        {:ok, Map.put(context, :entry, entry)}
      end

      when_ "the agent looks for a way to erase it on the module that owns the log", context do
        exported = CodeMySpec.Activity.__info__(:functions)
        {:ok, Map.put(context, :exported_functions, exported)}
      end

      then_ "no delete, remove or update function exists to call", context do
        erasing_names = ~w(delete delete_entry remove remove_entry update update_entry)a

        found = Enum.filter(context.exported_functions, fn {name, _arity} -> name in erasing_names end)

        assert found == [],
               "Activity exposes #{inspect(found)} — an erase path exists after all"

        {:ok, context}
      end

      then_ "the entry recorded before the search is still there, unchanged", context do
        [surviving] = CodeMySpec.Activity.list_for_resource(context.scope, "servers")

        assert surviving.id == context.entry.id
        assert surviving.summary == context.entry.summary

        {:ok, context}
      end
    end
  end
end
