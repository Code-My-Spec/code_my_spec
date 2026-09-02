defmodule CodeMySpec.McpServers.Devops.Tools.AdoptRepository do
  @moduledoc """
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
  commits only when the checkout has no commit at all yet, and the one other
  commit this can make (`commit_owner_patch/1`) touches only the generated CI
  workflow file, explicitly, never a broad `add -A`. Uncommitted local
  changes and untracked files in the working tree are not staged, committed,
  or pushed as a side effect of adopting.

  ## Synchronous, deliberately

  `run_devops_setup` fires the sequence and returns immediately, because a
  real run can take minutes and the MCP transport's call timeout is far
  shorter — but that shape also means a caller never learns whether a step
  actually ran, only that starting it was attempted. A push is seconds, not
  minutes, so this waits for the real outcome and reports it: adopted and
  pushed, a git/GitHub error with its own message, or a run already in
  flight for this project (same `RunLock` `run_devops_setup` itself
  respects, held here explicitly since calling the step directly bypasses
  the wrapper that normally acquires it). No more guessing from an
  unchanged `devops_status` whether anything happened.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Resources

  schema do
    field :repository_name, :string,
      required: true,
      doc: "The GitHub repository's exact name, e.g. \"market_my_spec\" — not a guess."

    field :branch, :string,
      doc: "The checkout's actual default branch, if it isn't \"main\" (e.g. \"master\")."

    field :owner, :string,
      doc:
        "The account or organisation the repository actually lives under, if it " <>
          "is not the connected account's own login (e.g. \"Code-My-Spec\")."
  end

  @impl true
  def execute(%{repository_name: repository_name} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope) do
      scope = Resources.project_scope(scope, project)
      opts = run_opts(repository_name, params)

      RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, :repository, opts) end)
      |> reply(repository_name, project, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp reply({:error, {:already_running, started_at}}, _name, _project, frame) do
    since = started_at && " (started #{started_at})"
    {:reply, error("a setup run is already in progress for this project#{since} — call devops_status rather than retrying"), frame}
  end

  defp reply({:ok, step}, repository_name, project, frame) do
    {:reply,
     ok("Adopted #{repository_name} for #{project.name} — repository step is now #{step.state}."),
     frame}
  end

  defp reply({:halt, _step, reason}, repository_name, _project, frame) do
    {:reply, error("could not adopt #{repository_name}: #{reason}"), frame}
  end

  defp run_opts(repository_name, params) do
    [adopt: true, name: repository_name]
    |> maybe_put(:branch, Map.get(params, :branch))
    |> maybe_put(:owner, Map.get(params, :owner))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not adopt the repository: #{inspect(reason)}")
end
