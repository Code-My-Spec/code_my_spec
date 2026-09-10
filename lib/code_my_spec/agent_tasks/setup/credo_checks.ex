defmodule CodeMySpec.AgentTasks.Setup.CredoChecks do
  @moduledoc """
  Setup step: .credo.exs configured with custom check paths.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, ".credo.exs", :custom_checks, "`.credo.exs` not found") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok,
     """
     # Configure Credo Custom Checks

     Create local checks directory:
     ```bash
     mkdir -p .code_my_spec/credo_checks/local
     ```

     Edit `.credo.exs`. Above the `%{configs: ...}` map, resolve the globs and
     refuse to run on an empty result:

     ```elixir
     check_globs = [
       ".code_my_spec/credo_checks/framework/**/*.ex",
       ".code_my_spec/credo_checks/local/**/*.ex"
     ]

     if check_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.empty?() do
       raise \"\"\"
       .credo.exs found no custom checks to load.

       These live in the `.code_my_spec` submodule, which git leaves empty on a
       fresh clone or `git worktree add`. Initialize it:

           git submodule update --init
       \"\"\"
     end
     ```

     Then inside the config:

     ```elixir
     requires: check_globs,
     checks: %{
       extra:
         if(File.exists?(".code_my_spec/credo_checks/framework/checks.exs"),
           do: elem(Code.eval_file(".code_my_spec/credo_checks/framework/checks.exs"), 0),
           else: []
         )
     }
     ```

     The guard is not optional decoration. A `requires:` glob that matches
     nothing loads nothing, prints no warning, and reports a clean bill of
     health — a worktree in that state reported 2 findings where the same commit
     reported 244. A lint that cannot lint has to fail like a broken build
     rather than pass like a clean one.
     """}
  end
end
