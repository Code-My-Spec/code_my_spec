defmodule CodeMySpecSpex.Story1149.Criterion2421Spex do
  @moduledoc "Main cannot execute a command in another project's working copy."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main cannot work in another project's copy", criterion: 2421 do
    scenario "a foreign working_copy_id cannot run a command" do
      given_ "Main is running and a copy belongs to another project", context do
        context = AttachmentHelpers.setup(context)

        other_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Other Project",
            module_name: "OtherProject"
          })

        other_scope = %{
          context.scope
          | active_project: other_project,
            active_project_id: other_project.id
        }

        foreign_copy = AttachmentHelpers.copy(other_scope, "foreign")
        {:ok, Map.put(context, :foreign_copy, foreign_copy)}
      end

      when_ "Main runs a command naming the foreign copy", context do
        result =
          AttachmentHelpers.result(context, "bash", %{
            working_copy_id: context.foreign_copy.id,
            command: "touch forbidden"
          })

        {:ok, Map.put(context, :command_result, result)}
      end

      then_ "the call is refused and nothing runs in the foreign copy", context do
        assert match?({:error, _}, context.command_result)
        refute File.exists?(Path.join(context.foreign_copy.root, "forbidden"))
        assert File.read!(Path.join(context.foreign_copy.root, "identity.txt")) == "foreign"
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
