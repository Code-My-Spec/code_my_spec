defmodule CodeMySpec.Provisioning.Tools.AdoptRepository do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Tools.Starter
  alias CodeMySpec.Resources

  @impl true
  def name, do: "adopt_repository"

  @impl true
  def description do
    """
    Adopt an existing GitHub repository as a project's remote, by its real name.

    `run_devops_setup`'s repository step derives the name it looks for from the
    project's own display name — lowercase, non-alphanumeric runs collapsed to
    a single dash — and only reaches the adopt-vs-create decision once a repo
    of that exact derived name is found. A real repo named any other way
    (underscores, or a different word entirely) is a lookup miss, not a
    collision: setup would silently create a second, empty, unrelated
    repository and push the current working tree into it, never considering
    the real one.

    This runs the same repository step by the repository's own real name
    instead of a guessed one, so it reaches the real repo directly and adopts
    it — same push-and-prove behavior `run_devops_setup` would otherwise do,
    just aimed correctly.

    ## `owner` is the other half of "the real repo"

    A name alone still is not enough when the repository lives in an
    organisation rather than the connected account's own login.
    `Repository.ensure/3` looks up `owner || authenticated_owner(scope)` — the
    authenticated user's own account — when nothing else is said, and this
    tool had no way to say otherwise. Found live: a project whose real
    repository is `Code-My-Spec/broken-oaths` adopted `johns10/broken-oaths`
    instead — a *different*, genuinely existing repository that happened to
    share the name under the account the OAuth token authenticates as — and
    failed the push with "origin already points at
    https://github.com/Code-My-Spec/broken-oaths.git, not
    https://github.com/johns10/broken-oaths.git", which reads as the wrong
    repository having been *found*, not as a parameter that was silently never
    offered. `owner` here is passed straight through as `Repository.ensure/3`'s
    own `:owner` opt, which already worked for both a personal account and an
    organisation login — the gap was only ever this tool's schema.

    `push/3`'s default branch is `"main"`, which the repository step never
    overrides — a real checkout whose default branch is anything else (a
    pre-existing `master`, for instance) would push nothing, since `git push
    origin main` has no local `main` to push. Safe (it fails cleanly rather
    than pushing the wrong content), but still a step that would otherwise
    fail for no reason a caller could see, so this exposes the same override
    `push/3` already supports.

    Only pushes what is already committed — `ensure_commit/1` stages and
    commits only when the checkout has no commit at all yet. Uncommitted local
    changes and untracked files in the working tree are not staged, committed,
    or pushed as a side effect of adopting.

    ## Returns when the run starts, not when it finishes

    A push is normally seconds, but a slow network, a large repository, or
    GitHub itself can run this well past the code-mode sandbox's 30s wall
    clock (issue 4f7929e4) — this used to hold `RunLock` and wait for the real
    push inline, on the stated bet that "a push is seconds, not minutes",
    which is a considered bet, not a guarantee. The spawned task claims this
    project's own lock and only then acks, the same handshake
    `run_provisioning_step` uses: the reply is "started" or "already running";
    an agent that started it is messaged the outcome, any other caller watches
    `devops_status`.
    """
  end

  @impl true
  def params do
    %{
      owner:
        {:meta, :string,
         [
           description:
             "The account or organisation the repository actually lives under, if it is not the connected account's own login (e.g. \"Code-My-Spec\")."
         ]},
      branch:
        {:meta, :string,
         [
           description:
             "The checkout's actual default branch, if it isn't \"main\" (e.g. \"master\")."
         ]},
      repository_name:
        {:required,
         {:meta, :string,
          [
            description:
              "The GitHub repository's exact name, e.g. \"market_my_spec\" — not a guess."
          ]}}
    }
  end

  @impl true
  def call(%{repository_name: repository_name} = params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope = Resources.project_scope(scope, project)
      opts = run_opts(repository_name, params)
      starter = Starter.new(scope, context, "repository (#{repository_name})")

      scope
      |> start_adopt_async(project, opts, starter, repository_name)
      |> reply(repository_name, project, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  # `provisioning_run_async` is the same flag `run_provisioning_step` reads.
  # `config/test.exs` pins it false, so every existing test keeps running
  # this inline, waiting for the real push on the caller's own connection.
  defp start_adopt_async(scope, project, opts, starter, repository_name) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true ->
        spawn_adopt_async(scope, project, opts, starter, repository_name)

      _ ->
        RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, :repository, opts) end)
    end
  end

  # Same handshake as `RunProvisioningStep.spawn_step_async/5`: the spawned
  # task claims `RunLock` first and only then signals, so the caller learns
  # "running" or "refused" in milliseconds, out of reach of this call's own
  # timeouts.
  defp spawn_adopt_async(scope, project, opts, starter, repository_name) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(
          project.id,
          fn ->
            send(parent, {ref, :locked})
            Provisioning.run_step(scope, :repository, opts)
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused ->
            send(parent, {ref, refused})

          finished ->
            Starter.tell(starter, outcome_message(finished, repository_name, project.name))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp reply({:ok, :started}, repository_name, _project, context) do
    ok("Adopting #{repository_name} — #{Starter.then_what(context[:agent_id])}")
  end

  # The synchronous (test-mode) outcome: `Provisioning.run_step/3`'s own result.
  defp reply({:ok, step}, repository_name, project, _context) do
    ok("Adopted #{repository_name} for #{project.name} — repository step is now #{step.state}.")
  end

  defp reply({:halt, _step, reason}, repository_name, _project, _context) do
    error("could not adopt #{repository_name}: #{reason}")
  end

  defp reply({:error, {:already_running, started_at}}, _name, _project, _context) do
    since = started_at && " (started #{started_at})"

    error(
      "a setup run is already in progress for this project#{since} — call devops_status rather than retrying"
    )
  end

  defp reply({:error, :lock_handshake_timeout}, repository_name, _project, _context) do
    error("could not confirm adopting #{repository_name} started — try again shortly")
  end

  @doc false
  def outcome_message({:ok, %{state: state}}, repository_name, project_name),
    do:
      "Adopted #{repository_name} for #{project_name} — repository step is now #{state}. " <>
        answer()

  def outcome_message({:halt, _step, reason}, repository_name, project_name),
    do: "Could not adopt #{repository_name} for #{project_name}: #{reason}. #{answer()}"

  defp answer, do: "This is the outcome of the adopt you started — act on it now."

  defp run_opts(repository_name, params) do
    [adopt: true, name: repository_name]
    |> maybe_put(:branch, Map.get(params, :branch))
    |> maybe_put(:owner, Map.get(params, :owner))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not adopt the repository: #{inspect(reason)}"}
end
