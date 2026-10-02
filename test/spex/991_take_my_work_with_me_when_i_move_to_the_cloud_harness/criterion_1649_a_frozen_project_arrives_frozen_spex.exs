defmodule CodeMySpecSpex.Story991.Criterion1649Spex do
  @moduledoc """
  Story 991 — Take my work with me when I move to the cloud harness
  Criterion 1649 — A project frozen at the source arrives frozen, and a project already frozen at the destination keeps its own stamp.

  Components as records, step 6 (3aeb66cf): components and their dependencies
  are authored records, so they travel. The source graph is built through the
  tools, the migration goes through the endpoint, and the cloud project is read
  back through `get_component`, `show_architecture` and `freeze_components`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  # The cloud project, as a context the graph helpers can read.
  defp cloud(context) do
    cloud = Fixtures.paid(Fixtures.other_project_scope(context.scope, "Cloud"))
    %{context | scope: cloud, project: %{cloud.active_project | module_name: app(context)}}
  end

  defp migrate!(context, cloud) do
    payload = context.scope |> Fixtures.exported() |> Jason.encode!() |> Jason.decode!()
    response = Fixtures.migrate(cloud.scope, payload)
    assert response.status == 200, response.resp_body
    response
  end

  spex "A project frozen at the source arrives frozen, and a project already frozen at the destination keeps its own stamp",
    criterion: 1649 do
    scenario "Sam moves a project whose architecture is authored" do
      given_ "Sam's local project: Accounts with User under it, and Web depending on Accounts, frozen",
             context do
        app = app(context)

        accounts =
          ComponentHelpers.create(context.scope,
            name: "Accounts",
            module_name: "#{app}.Accounts",
            type: "context",
            description: "Who uses it"
          )

        ComponentHelpers.create(context.scope,
          name: "User",
          module_name: "#{app}.Accounts.User",
          type: "schema",
          parent_component_id: accounts.id
        )

        web =
          ComponentHelpers.create(context.scope,
            name: "Web",
            module_name: "#{app}.Web",
            type: "context"
          )

        depend!(context, web, accounts)
        freeze(context, write: true)
        {:ok, Map.put(context, :cloud, cloud(context))}
      end

      when_ "Sam migrates it", context do
        migrate!(context, context.cloud)
        {:ok, context}
      end

      then_ "the cloud project is frozen", context do
        assert freeze(context.cloud) =~ "already frozen"
        {:ok, context}
      end
    end
  end
end
