defmodule CodeMySpecSpex.Story987.Criterion8190Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8190 — A written implementation file satisfies implementation_file.

  Covers Rule "Writing the artifact a requirement gates on satisfies that
  requirement, without any further action by the agent."

  `implementation_file` is a `file_exists` check scoped to a component's *own*
  files, so a file nothing owns is invisible to it. The harness channel ran
  `FileSync.reconcile/2` and stopped there; `ComponentSync`, which writes
  `component_id` back onto each row, only ran on the local path.

  Drill 11 finished the whole project chain with 157 tests passing and still
  reported 15 of these open — all 66 implementation files synced, not one
  linked.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent's module satisfies the requirement that asked for it" do
    scenario "writing the module at the component's conventional path satisfies implementation_file" do
      given_ "a component has a spec and no implementation", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/spec/my_app/widgets.spec.md",
            "# MyApp.Widgets\n\nStores widgets.\n\n## Type\n\ncontext\n"
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      when_ "the agent writes the module and the harness delivers its manifest", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/widgets.ex",
            "defmodule MyApp.Widgets do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        component =
          context.scope
          |> Fixtures.list_components()
          |> Enum.find(&(&1.module_name == "MyApp.Widgets"))

        {:ok, Map.put(context, :component, component)}
      end

      then_ "implementation_file is satisfied for that component", context do
        assert context.component, "the spec should have produced a component"

        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "implementation_file",
                 :component,
                 context.component.id
               ),
               """
               The module is on disk and synced, but nothing owns it, so the
               requirement scoped to that component cannot see it. That is how a
               finished project reports fifteen requirements open.
               """

        {:ok, context}
      end
    end
  end
end
