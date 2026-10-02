defmodule CodeMySpecSpex.Story991.Criterion1650Spex do
  @moduledoc """
  Story 991 — Take my work with me when I move to the cloud harness
  Criterion 1650 — Migrating a project twice adds no component or dependency a second time.

  Components as records, step 6 (3aeb66cf): components and their dependencies
  are authored records, so they travel. The source graph is built through the
  tools, the migration goes through the endpoint, and the cloud project is read
  back through `get_component` and `show_architecture`.
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

  spex "Migrating a project twice adds no component or dependency a second time",
    criterion: 1650 do
    scenario "Sam moves a project whose architecture is authored" do
      given_ "Sam's local project: Accounts with User under it, and Web depending on Accounts",
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
        {:ok, Map.put(context, :cloud, cloud(context))}
      end

      when_ "Sam migrates it twice", context do
        migrate!(context, context.cloud)
        first = snapshot(context.cloud)
        migrate!(context, context.cloud)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the second run changed nothing", context do
        assert snapshot(context.cloud) == context.first
        {:ok, context}
      end
    end
  end

  # Order-free: neither tool promises an order.
  defp snapshot(cloud) do
    {listed(cloud)
     |> Jason.decode!()
     |> Map.fetch!("components")
     |> Enum.sort_by(& &1["module_name"]),
     cloud |> architecture() |> String.split("\n") |> Enum.sort()}
  end
end
