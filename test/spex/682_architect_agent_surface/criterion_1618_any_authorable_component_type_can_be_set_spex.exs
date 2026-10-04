defmodule CodeMySpecSpex.Story682.Criterion1618Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1618 — Any authorable component type, infrastructure included, can
  be set when creating or updating a component.

  `update_component` offered context and coordination_context only, and
  `create_component` had no infrastructure. Surface: both tools, observed
  through `get_component`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Components.Tools.GetComponent
  alias CodeMySpec.McpServers.Components.Tools.UpdateComponent
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  @types ~w(context coordination_context live_context schema behaviour json
            liveview liveview_component controller module infrastructure)

  defp frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  defp type_of(context, id) do
    {:reply, reply, _frame} = GetComponent.execute(%{component_id: id}, frame(context))
    response_text(reply)
  end

  spex "Any authorable component type, infrastructure included, can be set when creating or updating a component",
    criterion: 1618 do
    scenario "infrastructure, at creation" do
      given_ "a project with no components", context do
        {:ok, Map.put(context, :app, context.project.module_name || "MyApp")}
      end

      when_ "the agent creates an infrastructure component", context do
        {:reply, reply, _frame} =
          CreateComponent.execute(
            %{name: "Repo", module_name: "#{context.app}.Repo", type: "infrastructure"},
            frame(context)
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is created as infrastructure", context do
        refute context.reply.isError, response_text(context.reply)
        assert response_text(context.reply) =~ "infrastructure"
        {:ok, context}
      end
    end

    scenario "every type, by update" do
      given_ "a module component", context do
        app = context.project.module_name || "MyApp"

        component =
          ComponentHelpers.create(context.scope,
            name: "Thing",
            module_name: "#{app}.Thing",
            type: "module"
          )

        {:ok, Map.put(context, :component, component)}
      end

      when_ "the agent sets each authorable type in turn", context do
        seen =
          for type <- @types do
            {:reply, reply, _frame} =
              UpdateComponent.execute(
                %{component_id: context.component.id, type: type},
                frame(context)
              )

            {type, reply.isError, type_of(context, context.component.id)}
          end

        {:ok, Map.put(context, :seen, seen)}
      end

      # What `tools/list` hands an agent. The enum was enforced there, not in
      # `execute/2`, so an agent never got to send any other type.
      then_ "both tools advertise every one of them", context do
        for tool <- [CreateComponent, UpdateComponent] do
          assert get_in(tool.input_schema(), ["properties", "type", "enum"]) == @types,
                 "#{inspect(tool)} does not offer every authorable type"
        end

        {:ok, context}
      end

      then_ "each one is accepted and reads back", context do
        for {type, error?, read} <- context.seen do
          refute error?, "update_component refused type #{type}"
          assert read =~ ~s("type":"#{type}") or read =~ ~s("type": "#{type}"), "#{type}: #{read}"
        end

        {:ok, context}
      end
    end
  end
end
