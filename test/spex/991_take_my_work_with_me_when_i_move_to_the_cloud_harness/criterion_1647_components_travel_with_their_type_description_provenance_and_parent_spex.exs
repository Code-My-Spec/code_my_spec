defmodule CodeMySpecSpex.Story991.Criterion1647Spex do
  @moduledoc """
  Story 991 — Take my work with me when I move to the cloud harness
  Criterion 1647 — Migrating a project carries its components with their type, description, provenance and parent, matched by module name.

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

  spex "Migrating a project carries its components with their type, description, provenance and parent, matched by module name",
    criterion: 1647 do
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

      then_ "the cloud has each component as it was", context do
        app = app(context)
        accounts = component(context.cloud, "#{app}.Accounts")
        user = component(context.cloud, "#{app}.Accounts.User")

        assert accounts["type"] == "context"
        assert accounts["description"] == "Who uses it"
        assert accounts["provenance"] == "authored"
        assert user["type"] == "schema"
        assert user["parent_component_id"] == accounts["id"]
        {:ok, context}
      end
    end
  end
end
