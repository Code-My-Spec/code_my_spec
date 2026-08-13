defmodule Mix.Tasks.Cms.OnboardHarness do
  @shortdoc "Onboard this working copy onto the harness"

  @moduledoc """
  Take the working copy this runs in from checkout to ready.

      mix cms.onboard_harness [--root PATH]

  The CodeMySpec-side entry point. The portable work lives in `client_utils`,
  because a generated application depends on that and not on this — so it is the
  only placement where both can onboard themselves with one command. This task
  delegates there and adds whatever is specific to CodeMySpec.

  ## What it will not do

  **It never creates, migrates or drops a database.** It names the databases the
  working copy needs and prints the exact commands; running them is the agent's
  job. The rule exists because the removed version of this shelled out to `mix`
  with an environment that had `MIX_ENV` scrubbed out of it, so it ran against
  **dev** — the database every agent shares — and a sibling truncate emptied it
  three times on 2026-08-13.

  **It does not create worktrees.** The agent makes its own and runs this inside
  it. `--root` exists only to name a directory other than the current one.

  ## Why the work is in `onboard/1` and not in `run/1`

  Every file it writes goes through `Environments`, and `onboard/1` takes the
  environment rather than reaching for one. `run/1` is the thin half: it turns
  `--root` (or the current directory) into a local environment and hands it over.

  That is what lets the spex drive this against the in-memory environment instead
  of a real directory — a task that called `File.write!/2` could only be tested by
  configuring some actual working copy, and the nearest one is always the copy the
  suite is running in.

  Not implemented — story 1013's spex are the contract, and they are red until
  this is filled in.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Environments

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [root: :string, project: :string])

    opts
    |> environment()
    |> onboard()
  end

  # `--project` names an already-registered environment and wins over `--root`.
  # That is the seam the spex use: `CodeMySpecSpex` may reference
  # `CodeMySpec.Environments` and nothing else of ours, so a spec registers the
  # in-memory environment and names it here, driving this task the way an engineer
  # does rather than calling into it across a boundary that forbids exactly that.
  #
  # A flag rather than an environment variable because the project's own Credo
  # check denies `System.put_env` inside `_spex.exs` — "specs must act through the
  # public surfaces". It was right to: a spec that has to mutate global process
  # state to be observable is describing a surface with no way in.
  defp environment(opts) do
    case Keyword.fetch(opts, :project) do
      {:ok, project_id} -> registered!(project_id)
      :error -> local!(Keyword.get(opts, :root) || File.cwd!())
    end
  end

  # `lookup_registered/1` returns the environment or nil — not an ok-tuple, unlike
  # `create/2` beside it.
  defp registered!(project_id) do
    case Environments.lookup_registered(project_id) do
      nil -> Mix.raise("no environment is registered for project #{project_id}")
      environment -> environment
    end
  end

  defp local!(root) do
    case Environments.create(:local, working_dir: root) do
      {:ok, environment} -> environment
      {:error, reason} -> Mix.raise("could not open #{root}: #{inspect(reason)}")
    end
  end

  @doc """
  Onboard the working copy `environment` points at.

  Takes the environment so this is drivable against the in-memory one. Writes
  nothing outside it, and issues no DDL.
  """
  @spec onboard(CodeMySpec.Environments.Environment.t()) :: :ok
  def onboard(_environment) do
    Mix.raise("""
    cms.onboard_harness is not implemented yet.

    Story 1013 ("A working copy comes onto the harness fully configured") holds
    the contract, in test/spex/1013_*/. Those spex are red by design and are what
    this task gets built to satisfy.
    """)
  end
end
