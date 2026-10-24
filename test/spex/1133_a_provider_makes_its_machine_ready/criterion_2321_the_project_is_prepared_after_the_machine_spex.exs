defmodule CodeMySpecSpex.Story1133.Criterion2321Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2321 — The project is prepared after the machine.

  Product's decision on this (the question this answers): `just dev-setup`
  is the last step of the same setup run, triggered automatically right
  after the machine steps succeed and the project is created or linked —
  nobody presses anything extra. This drives story 1112's existing
  link-project flow (the same surface criterion 2040 drives) and asserts
  the new step runs after it, through a fake `just` on PATH that only
  records its invocation — what it would really do (fetch deps, create and
  migrate the database) is not something a spec observes through the
  desktop UI.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine

  defp fresh_machine(context) do
    {:ok, context} = DesktopSetupHelpers.fresh_machine(context)
    {:ok, DesktopSetupHelpers.with_just(context)}
  end

  spex "The project's dev-setup runs once the machine is ready", criterion: 2321 do
    scenario "Setup finishes the machine steps by linking an existing project" do
      given_ "Sam's machine is ready", context do
        project_dir = Path.join(context.machine_root, "dev_setup_app")

        :ok =
          ExecutionContexts.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule DevSetupApp.MixProject do
              use Mix.Project
              def project, do: [app: :dev_setup_app, version: "0.1.0", deps: []]
              def application, do: []
            end
            """
          )

        {:ok, _snapshot} = CmsHarness.Setup.check_prerequisites()

        {:ok,
         Map.merge(context, %{
           project_dir: project_dir,
           commands_before_project: read_machine_file!(context, context.command_log)
         })}
      end

      when_ "setup finishes the machine steps by linking the project", context do
        assert {:ok, _snapshot} = DesktopSetupHelpers.connect_setup_project(context)
        {:ok, context}
      end

      then_ "the project's `just dev-setup` runs, and only after the machine steps", context do
        commands = read_machine_file!(context, context.command_log)

        assert String.starts_with?(commands, context.commands_before_project),
               "the recorded machine-step commands changed once the project was linked, " <>
                 "so dev-setup cannot be read as having run strictly after them:\n\n#{commands}"

        added = String.replace_prefix(commands, context.commands_before_project, "")

        assert added =~ ~r/^just dev-setup\b/m,
               "expected `just dev-setup` to run once the machine was ready and the project " <>
                 "was linked, after every machine-step command:\n\n#{commands}"

        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = ExecutionContexts.read_file(context.machine_environment, path)
    contents
  end
end
