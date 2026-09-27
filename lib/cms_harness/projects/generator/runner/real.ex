defmodule CmsHarness.Projects.Generator.Runner.Real do
  @moduledoc """
  `Environments.cmd/4` rather than a bare `System.cmd/3`: a real harness is a
  Burrito release, and its own `ROOTDIR`/`BINDIR`/`RELEASE_*` would otherwise
  leak into the child `mix` it spawns and make that child try to boot from the
  release's own extracted ERTS instead of the machine's real Elixir install
  ("cannot get bootfile") — `Environments.Local.cmd/4` is what strips those
  before the child ever starts.

  Measured directly, not theorised: installing an Elixir-version-mismatched
  `cms_new` archive into this box's own asdf install broke every `mix`
  invocation on it until the archive was removed by hand. A generated app's
  own `mix cms.new` subprocess is exactly the kind of child process that class
  of leak would hit.
  """

  @behaviour CmsHarness.Projects.Generator.Runner

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @impl true
  def cmd(cwd, command, args) do
    env = Environment.new(:local, cwd)

    case Environments.cmd(env, command, args, []) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error,
         "#{command} #{Enum.join(args, " ")} exited #{code} in #{cwd}: #{String.slice(output, -2000, 2000)}"}
    end
  end
end
