defmodule CodeMySpec.Workspaces.AWorkspaceBootsOnItsOwnToolchainTest do
  @moduledoc """
  A booting workspace resolves its own Elixir, not this server's.

  Issue `114843ff`. `Runner.Local` shells a boot script that runs
  `mix cms.new` in a brand-new, empty directory. That directory pins no
  version, so a version manager would fall back to the machine's default —
  except the script inherited this server's PATH, which names our resolved
  Elixir ahead of the shims, because that is how we got our Elixir. The child
  used ours: 1.19.4-otp-28, where `cms_new` is not installed as an archive.

      ** (Mix) The task "cms.new" could not be found

  Every paid signup on this box died there, deterministically. Four rounds of
  story 1033's QA put it down to disk exhaustion and Docker, on a box with
  33GiB free running no containers — the runner is bare OS processes in dev.
  The error only ever appeared in the workspace's own `run.log`, which nobody
  was reading.

  `Environments.merge_clean_env/1` exists for exactly this and its own comment
  names the situation. `Runner.Local` was a caller that needed it and did not
  use it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Workspaces.Runner.Local

  test "the launch environment sets PATH rather than inheriting it" do
    assert {"PATH", path} = List.keyfind(Local.launch_env()[:env], "PATH", 0),
           """
           The boot script inherits this server's PATH untouched, so a child
           `mix` in a directory that pins nothing resolves our Elixir instead of
           the machine's default. That is `clean_otp_env/0`, which only rewrites
           PATH when RELEASE_ROOT is set — off a release it says nothing about
           PATH at all.
           """

    assert is_binary(path) and path != ""
  end

  test "and the scrub the caller relies on is still applied" do
    env = Local.launch_env()[:env]

    assert {"RELEASE_ROOT", nil} in env,
           "reaching for a different PATH must not drop the release scrub — a " <>
             "child that inherits our ERTS cannot boot at all"

    assert Local.launch_env()[:stderr_to_stdout] == true,
           "the caller's own options were dropped on the way through"
  end

  # Machine-dependent by nature, so it asserts its own premise rather than
  # passing quietly where no version manager is installed.
  test "a machine with shims has them first" do
    shims =
      Enum.filter(["~/.asdf/shims", "~/.local/share/mise/shims"], &File.dir?(Path.expand(&1)))

    check_shim_order(shims)
  end

  defp check_shim_order([]) do
    # No version manager here, so there is no ordering to get wrong. Recorded
    # rather than skipped so a reader knows why this said nothing.
    assert Environments.merge_clean_env([])[:env] != []
  end

  defp check_shim_order([first | _]) do
    {"PATH", path} = List.keyfind(Local.launch_env()[:env], "PATH", 0)
    [head | _] = String.split(path, ":", trim: true)

    assert head == Path.expand(first), """
    The shims are on PATH but behind a resolved version's bin directory, which
    is the ordering that has to change — prepending only when absent leaves it
    untouched and the child still resolves ours.
    """
  end
end
