defmodule CodeMySpecSpex.Story682.Criterion1653Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1653 — Deleting a component leaves its files in place, says which remain, and warns that code still naming the module will be rediscovered.

  Components are records (3aeb66cf): `delete_component` deletes the record and
  nothing else. Code is somebody's work, and while it names the module a sync
  discovers it again — so the reply says so rather than leaving the agent to
  find out.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Components.Tools.DeleteComponent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Deleting a component leaves its files in place, says which remain, and warns that code still naming the module will be rediscovered",
    criterion: 1653 do
    scenario "the architect deletes Accounts while its code exists" do
      given_ "Accounts designed, with its code written and synced", context do
        app = app(context)
        accounts = design!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Accounts")
        sync!(context)
        {:ok, Map.put(context, :accounts, accounts)}
      end

      when_ "the architect deletes Accounts", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, reply, _} = DeleteComponent.execute(%{component_id: context.accounts.id}, frame)

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :said, response_text(reply))}
      end

      then_ "the code is still there, the reply names it, and warns it will be rediscovered",
            context do
        path = "lib/#{Macro.underscore("#{app(context)}.Accounts")}.ex"

        assert Environments.file_exists?(context.environment, path)
        assert context.said =~ path
        assert context.said =~ "discovers it again"
        {:ok, context}
      end
    end
  end
end
