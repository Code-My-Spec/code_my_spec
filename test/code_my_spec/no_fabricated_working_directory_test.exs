defmodule CodeMySpec.NoFabricatedWorkingDirectoryTest do
  @moduledoc """
  Nothing reachable from a request may build a project environment out of
  `File.cwd!()`.

  On a developer's machine the current directory *is* the project, so the
  fallback reads as harmless. On a server it is the server's own checkout, and
  the failure is silent in both directions: writes land in the wrong repository,
  and reads report the project's files missing while they sit on the agent's
  disk.

  It has bitten three times. `Validators.mcp_working_dir/1` wrote a project's
  `AGENTS.md` into this repository; `ArchitectureDesign` read its proposal from
  here; `SpecStub.write_for_scope/2` left eight `e2e_todo` spec stubs in the
  worktree, and — the expensive half — left the agent's own spec directory
  empty, so every component it created had no dependency edges, read as an
  orphan, and made `architecture_designed` unsatisfiable.

  None of those failed a test. Each was found by reading a drill log.

  So the pattern is pinned. Adding `File.cwd!()` to a module that serves
  requests fails here, and the fix is to thread the caller's environment through
  or to refuse — never to guess.
  """

  use ExUnit.Case, async: true

  # Where a current directory genuinely is the project, with the reason.
  @allowed %{
    # The environment adapters' own primitive. `Local.create/1` is how a caller
    # asks for "an environment here", which is meaningful when someone asked.
    "lib/code_my_spec/environments/local.ex" => "adapter primitive: explicit :working_dir opt",
    "lib/code_my_spec/environments/cli.ex" => "adapter primitive, same as local",

    # Mix tasks and the CLI-only init path run on the machine holding the code.
    "lib/mix/tasks/set_story_component.ex" => "mix task: cwd is the project by definition",
    "lib/code_my_spec/agent_tasks/init/cli_config.ex" => "cms init, on the user's machine",
    "lib/code_my_spec/agent_tasks/init/phoenix_project.ex" => "cms init, on the user's machine",
    "lib/code_my_spec/agent_tasks/init.ex" => "cms init, on the user's machine",

    # The local desktop app: one machine, one project, cwd is it.
    "lib/code_my_spec_local_web/live/projects/form.ex" => "local desktop UI",
    "lib/code_my_spec/project_sync/file_watcher_server.ex" => "watches a local checkout",

    # Path arithmetic, not file access.
    "lib/code_my_spec/utils/paths.ex" => "Path.relative_to/2, touches no file"
  }

  # Prose mentioning the pattern is not the pattern — this module's own
  # moduledoc would otherwise fail it, and so would the comment explaining why
  # `Validators.mcp_working_dir/1` no longer has one.
  defp code_line?(line) do
    trimmed = String.trim(line)

    not String.starts_with?(trimmed, "#") and
      not String.contains?(line, "`File.cwd!()`") and
      String.contains?(line, "File.cwd!()")
  end

  test "no request-reachable module fabricates a working directory" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        path |> File.read!() |> String.split("\n") |> Enum.any?(&code_line?/1)
      end)
      |> Enum.reject(&Map.has_key?(@allowed, &1))
      |> Enum.sort()

    assert offenders == [],
           """
           These modules build a path from the server's current directory:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           On a server that directory is this repository, not the caller's
           project. Thread the caller's environment through, or return an error
           saying there is no working copy — the agent has the disk and can be
           told what to write. Do not guess.

           If the module genuinely only ever runs where cwd is the project, add
           it to @allowed with the reason.
           """
  end
end
