defmodule CmsHarness.Projects.Generator do
  @moduledoc """
  Turns a pending local project the server offered into a running checkout.

  The harness-side half of story `project_local_onboarding_is_harness_driven_not_server_driven`
  — a machine that is already running a harness generates and onboards a new
  project itself, the same way `docker/devbox/entrypoint.sh` does for a cloud
  container, minus the shell script: every step here is a Mix task this harness
  already needs `mix` for, so there is nothing a `.sh` file would add except a
  second place for the sequence to drift from this one.

  ## Each step checks whether it already happened

  Not "run once, remember it ran" — remembering would mean state that a
  restart loses, at exactly the point where losing it costs the most: this is
  called again on every heartbeat until the project stops being pending
  (`CmsHarness.WorkingCopyReporter` guarantees that, not this module), so a
  harness restarted mid-generation resumes from whatever is actually on disk
  rather than starting over or silently giving up.

  `mix deps.get`/`mix ecto.create`/`mix ecto.migrate` are safe to repeat — the
  underlying tasks are already idempotent, so they simply run again rather than
  being skipped. Generation and onboarding are not idempotent the same way
  (`mix cms.new` refuses a non-empty directory, and `mix harness.onboard` mints
  a *new* working copy every time it runs) — those two are gated on what is
  already on disk.

  ## What this deliberately does not do

  Prepare the machine itself. `mix`, Elixir and Postgres already being usable
  is step 1.5 of the onboarding plan and explicitly out of scope — this
  assumes an environment where a human could have typed the same three
  commands `IntakeLive.Workspace.local_commands/1` shows today, and fails
  loudly (logged, not raised) when that assumption does not hold. A harness
  that cannot generate one project still has every other job to do.
  """

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Projects
  alias CmsHarness.Projects.Generator.Runner

  @type pending :: %{
          id: String.t(),
          name: String.t(),
          app_name: String.t(),
          deploy_key: String.t()
        }

  @doc """
  Generate, onboard and start serving one pending project.

  `dir` is deterministic by default — `CmsHarness.Config.projects_root/0`
  joined with the project's own `app_name` — rather than wherever the process
  happens to be running, because nothing is sitting at a prompt to choose one,
  and a restart re-deriving it from the same inputs is how this resumes at
  all. `opts[:projects_root]` overrides the base directory; a test is the only
  caller with reason to, since `Config.projects_root/0` is otherwise a fixed
  answer derived from this machine's own `~/.codemyspec`.
  """
  @spec run(pending(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(pending, opts \\ [])

  def run(%{id: project_id, name: name, app_name: app_name, deploy_key: deploy_key}, opts) do
    root = Keyword.get(opts, :projects_root, Config.projects_root())
    dir = Path.join(root, app_name)

    with :ok <- ensure_generated(dir, name, app_name),
         :ok <- ensure_deps(dir),
         :ok <- ensure_database(dir),
         {:ok, working_copy_id} <- ensure_onboarded(dir, deploy_key),
         :ok <- ensure_linked(dir, working_copy_id, project_id) do
      case Projects.ensure_started(dir) do
        {:ok, _project} ->
          Logger.info("[CmsHarness] generated and onboarded #{name} at #{dir}")
          {:ok, dir}

        {:error, reason} ->
          {:error, {:serve, reason}}
      end
    end
  end

  # `mix.exs` existing is the whole check: a directory this far along either
  # finished generating or is mid-`deps.get`, and either way running
  # `mix cms.new` again would refuse the non-empty directory it now is.
  defp ensure_generated(dir, name, app_name) do
    if File.exists?(Path.join(dir, "mix.exs")) do
      :ok
    else
      Logger.info("[CmsHarness] generating #{name} at #{dir}")

      with :ok <- File.mkdir_p(Path.dirname(dir)),
           {:ok, _output} <-
             run_cmd(Path.dirname(dir), "mix", [
               "cms.new",
               dir,
               "--app",
               app_name,
               "--no-install"
             ]) do
        :ok
      else
        {:error, reason} -> {:error, {:generate, reason}}
      end
    end
  end

  defp ensure_deps(dir) do
    case run_cmd(dir, "mix", ["deps.get"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:deps_get, reason}}
    end
  end

  defp ensure_database(dir) do
    with {:ok, _output} <- run_cmd(dir, "mix", ["ecto.create"]),
         {:ok, _output} <- run_cmd(dir, "mix", ["ecto.migrate"]) do
      :ok
    else
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # A working copy id on file is the signal onboarding already ran — not
  # merely that it was attempted, since `mix harness.onboard` writes the id
  # and the id alone is the one thing this needs back. Re-running it would
  # mint a second working copy for a directory that already has one.
  defp ensure_onboarded(dir, deploy_key) do
    case HarnessConfig.read_file(dir) do
      {:ok, %{working_copy_id: id}} when is_binary(id) ->
        {:ok, id}

      :none ->
        onboard(dir, deploy_key)

      {:error, reason} ->
        {:error, {:onboard, reason}}
    end
  end

  defp onboard(dir, deploy_key) do
    with {:ok, _output} <-
           run_cmd(dir, "mix", [
             "harness.onboard",
             "--deploy-key",
             deploy_key,
             "--server-url",
             Config.server_url()
           ]),
         {:ok, %{working_copy_id: id}} <- HarnessConfig.read_file(dir) do
      {:ok, id}
    else
      :none -> {:error, {:onboard, :no_identity_written}}
      {:error, reason} -> {:error, {:onboard, reason}}
    end
  end

  # `mix harness.onboard` has no `--project` flag (confirmed against its own
  # source — it mints a working copy, nothing more), so the link is a second
  # step: patch `project_id` into the same file, once the id it minted is
  # known. `HarnessConfig.write/2` merges over whatever is already there
  # rather than this module reimplementing that merge — the same file
  # `preview_url`/`deploy_key` already survive a rewrite through.
  defp ensure_linked(dir, working_copy_id, project_id) do
    case HarnessConfig.read_file(dir) do
      {:ok, %{project_id: ^project_id}} ->
        :ok

      _ ->
        HarnessConfig.write(dir, %{working_copy_id: working_copy_id, project_id: project_id})
    end
  end

  defp run_cmd(cwd, command, args), do: Runner.impl().cmd(cwd, command, args)
end
