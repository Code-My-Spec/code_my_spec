defmodule CodeMySpecSpex.Story682.Criterion5832Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 5832 — Architect creates a stub component via the create_component tool.

  When the architect calls `create_component` with a module name, type, and
  description, the system creates a component DB row and writes a stub spec
  file at the conventional path. The body of the stub is left empty for the
  ComponentSpec phase to fill in later. This is the lightweight, single-call
  alternative to rewriting the full proposal in patch mode.

  Surface: `create_component` MCP tool, then `list_components` to observe the
  new component, plus a filesystem read for the spec stub.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.Paths

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The architect creates a stub component via the create_component tool" do
    scenario "stub spec and DB row are created without writing the full spec body" do
      given_ "no spec file exists at the conventional path for the new component",
             context do
        app = context.project.module_name || "MyApp"
        module_name = "#{app}.Notifications"
        spec_path = Paths.spec_file(Macro.underscore(module_name))

        refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "pre-condition failed: expected no spec file at #{spec_path}"

        {:ok,
         Map.merge(context, %{
           module_name: module_name,
           spec_path: spec_path
         })}
      end

      when_ "the architect calls create_component with module name, type, and description",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          name: "Notifications",
          module_name: context.module_name,
          type: "context",
          description: "Notifications domain context"
        }

        {:reply, response, _frame} = CreateComponent.execute(params, frame)

        {:ok, Map.put(context, :create_response, response)}
      end

      then_ "the tool reports success", context do
        refute context.create_response.isError,
               "expected create_component to succeed, got: #{inspect(context.create_response)}"

        {:ok, context}
      end

      then_ "the new component appears in list_components output", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListComponents.execute(%{}, frame)
        body = response_text(response)

        assert body =~ context.module_name,
               "expected #{context.module_name} in list_components output, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "a stub spec file exists at the conventional path", context do
        assert CodeMySpec.Environments.file_exists?(context.environment, context.spec_path),
               "expected stub spec at #{context.spec_path} to be created by create_component"

        {:ok, context}
      end

      then_ "the stub spec references the module name and type", context do
        {:ok, content} =
          CodeMySpec.Environments.read_file(context.environment, context.spec_path)

        assert content =~ context.module_name,
               "expected stub spec to mention the module name, got: #{inspect(content)}"

        assert content =~ "context",
               "expected stub spec to declare the component type, got: #{inspect(content)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
