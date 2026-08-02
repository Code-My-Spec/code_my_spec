defmodule CodeMySpec.Provisioning.Repository do
  @moduledoc """
  The project's Git remote — created or adopted through the user's own GitHub
  OAuth grant.

  ## An OAuth App, which means we own the picker

  Confirmed with the app owner: this is an OAuth App, not a GitHub App. An
  earlier draft of this module assumed the opposite — the `Ov23` client-id
  prefix is widely documented as indicating a GitHub App — and got the design
  backwards as a result.

  The difference is not cosmetic. A GitHub App has an installation screen
  where the user picks repositories, so a picker of our own would be wrong.
  An OAuth App has no such screen: the `repo` scope grants access to
  everything the user can reach, and choosing *which* repository is therefore
  our job. Hence `list_repositories/2`.

  It also means the grant is coarse and revocable only wholesale — Sam cannot
  withdraw one repository, only the whole authorization. Worth knowing rather
  than assuming per-repository control that does not exist.

  ## Adoption and collision are different things

  Both involve a repository that already exists, and conflating them produces
  one of two bugs.

  - **Adoption** (`adopt: true`) is Sam having chosen this repository. Setup
    takes it as the remote and creates nothing. Criterion 8179.
  - **Collision** is setup wanting a name and finding something already there
    that Sam has not pointed at. `{:name_taken, ...}` is returned with both
    choices and neither is taken on his behalf. Criterion 8185.

  Auto-adopting a collision could scribble on an unrelated project.
  Auto-renaming leaves Sam with a repository he did not choose and cannot
  easily find — the project form's existing `-docs` suffix habit is exactly
  that reflex.

  ## No credential fallback

  A revoked authorization returns `{:error, :github_not_connected}` and stops.
  There is deliberately no fallback to a platform token, a machine account, or
  a locally-authenticated `gh` — each would create the repository under the
  wrong account and look like success. `gh` in particular is authenticated as
  whoever installed it, which in a multi-tenant product is never the right
  answer.

  ## Done is a push, not a repository

  `run/3` completes only when a push lands, and records the commit. A
  repository that exists but rejects the push is not a remote: the grant may
  be read-only, the repository may be archived, the default branch may be
  protected. All three were observed while recording this story's cassettes —
  the archived case is where the real 403 came from. Reporting "repository created" there would be true
  and useless — the harness would fail on its first push, far from setup.
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.GitHub
  alias CodeMySpec.Users.Scope

  @type disposition :: :created | :adopted

  @type result :: %{
          state: :pushed | :name_taken | :not_connected | :create_failed | :push_rejected,
          disposition: disposition() | nil,
          repository: map() | nil,
          commit: String.t() | nil,
          pushed_at: DateTime.t() | nil,
          choices: [atom()] | nil,
          reason: String.t() | nil
        }

  @doc """
  The default repository name for a project — its name, slugified.

  A default, not a rule: `opts[:name]` overrides it.

  ## Examples

      iex> CodeMySpec.Provisioning.Repository.default_name(%{name: "Code My Spec"})
      "code-my-spec"
  """
  @spec default_name(map()) :: String.t()
  def default_name(%{name: name}) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Create the repository, or adopt one Sam has chosen.

  `opts`:
    * `:name` — overrides `default_name/1`
    * `:owner` — the account login; required to check for an existing repo
    * `:org` — create inside this organisation instead of the personal account
    * `:adopt` — `true` when Sam has chosen the existing repository
    * `:private` — defaults to `true`
  """
  @spec ensure(Scope.t(), map(), keyword()) ::
          {:ok, disposition(), map()}
          | {:name_taken, map()}
          | {:error, :github_not_connected}
          | {:error, term()}
  def ensure(%Scope{} = scope, project, opts \\ []) do
    name = Keyword.get(opts, :name) || default_name(project)
    owner = Keyword.get(opts, :owner)

    case existing(scope, owner, name) do
      {:ok, repo} -> resolve_existing(repo, name, opts)
      {:error, :not_found} -> create(scope, name, opts)
      {:error, _} = error -> error
    end
  end

  # Without an owner there is nothing to look up, so treat the name as free and
  # let GitHub arbitrate on create. Guessing an owner would check the wrong
  # account and report a free name that is not.
  defp existing(_scope, nil, _name), do: {:error, :not_found}
  defp existing(scope, owner, name), do: GitHub.get_repository(scope, owner, name)

  defp resolve_existing(repo, _name, opts) do
    case Keyword.get(opts, :adopt, false) do
      true ->
        {:ok, :adopted, repo}

      false ->
        {:name_taken,
         %{
           repository: repo,
           choices: [:adopt, :rename],
           message:
             "A repository named #{repo["name"]} already exists on this account. " <>
               "Adopt it as this project's remote, or choose another name."
         }}
    end
  end

  defp create(scope, name, opts) do
    attrs = %{
      name: name,
      private: Keyword.get(opts, :private, true),
      auto_init: true
    }

    created =
      case Keyword.get(opts, :org) do
        nil -> GitHub.create_repository(scope, attrs)
        org -> GitHub.create_org_repository(scope, org, attrs)
      end

    with {:ok, repo} <- created, do: {:ok, :created, repo}
  end

  @doc """
  Push the working tree to the remote and return the commit that landed.

  Runs through `Environments.cmd/4` so it executes on whichever device the
  environment names.

  ## It initialises, because a new project has no git yet

  This step exists for a project that was just generated: the files are there,
  git is not. An earlier version assumed a repository and failed with
  `git exited 128` on exactly the case it was built for. So it inits when
  absent, commits when there is nothing to push, and sets the remote whether
  or not `origin` already exists.

  Every git invocation captures stderr. Without `stderr_to_stdout: true`,
  `System.cmd/3` discards it and a failure reports only its exit code —
  which is how the first failure here said "git exited 128:" and nothing
  else.
  """
  @spec push(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def push(env, remote_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    git = Keyword.get(opts, :git_bin, "git")
    run = fn args -> Environments.cmd(env, git, args, stderr_to_stdout: true) end

    with :ok <- ensure_repo(run, branch),
         :ok <- ensure_commit(run),
         :ok <- set_remote(run, remote_url),
         {_, 0} <- run.(["push", "-u", "origin", branch]),
         {sha, 0} <- run.(["rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, "git exited #{status}: #{String.trim(to_string(output))}"}
    end
  end

  defp ensure_repo(run, branch) do
    case run.(["rev-parse", "--is-inside-work-tree"]) do
      {_, 0} ->
        :ok

      _ ->
        case run.(["init", "-b", branch]) do
          {_, 0} -> :ok
          {output, status} -> {:error, "git init failed (#{status}): #{String.trim(output)}"}
        end
    end
  end

  # A repository with no commit has nothing to push, and `git push` on one
  # fails in a way that reads like a permissions problem.
  defp ensure_commit(run) do
    case run.(["rev-parse", "HEAD"]) do
      {_, 0} ->
        :ok

      _ ->
        with {_, 0} <- run.(["add", "-A"]),
             {_, 0} <- run.(["commit", "-m", "Initial commit"]) do
          :ok
        else
          {output, status} -> {:error, "could not create the initial commit (#{status}): #{String.trim(output)}"}
        end
    end
  end

  # `remote add` fails when origin exists, which is an ordinary state on a
  # retry rather than an error.
  defp set_remote(run, url) do
    case run.(["remote", "add", "origin", url]) do
      {_, 0} ->
        :ok

      _ ->
        case run.(["remote", "set-url", "origin", url]) do
          {_, 0} -> :ok
          {output, status} -> {:error, "could not set the remote (#{status}): #{String.trim(output)}"}
        end
    end
  end

  @doc """
  Ensure the repository exists and prove it by pushing to it.

  Returns a result whose `pushed_at` is set only when a push actually landed.
  As with the deploy, content and widget steps, there is no field claiming
  success independently of the proof.
  """
  @spec run(Scope.t(), Environments.Environment.t(), map(), keyword()) :: result()
  def run(%Scope{} = scope, env, project, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    push_fun = Keyword.get(opts, :push, &push/3)

    case ensure(scope, project, opts) do
      {:ok, disposition, repo} ->
        prove(repo, disposition, env, push_fun, now, opts)

      {:name_taken, collision} ->
        %{
          state: :name_taken,
          disposition: nil,
          repository: collision.repository,
          commit: nil,
          pushed_at: nil,
          choices: collision.choices,
          reason: collision.message
        }

      {:error, :github_not_connected} ->
        failure(
          :not_connected,
          "GitHub is not connected for this project. Reconnect the CodeMySpec app on " <>
            "GitHub and run this step again — setup will not create the repository under " <>
            "any other account."
        )

      {:error, reason} ->
        failure(:create_failed, "Could not create the repository: #{inspect(reason)}")
    end
  end

  defp prove(repo, disposition, env, push_fun, now, opts) do
    case push_fun.(env, repo["clone_url"] || repo["ssh_url"], opts) do
      {:ok, commit} ->
        %{
          state: :pushed,
          disposition: disposition,
          repository: repo,
          commit: commit,
          pushed_at: now.(),
          choices: nil,
          reason: nil
        }

      {:error, reason} ->
        %{
          state: :push_rejected,
          disposition: disposition,
          repository: repo,
          commit: nil,
          pushed_at: nil,
          choices: nil,
          reason:
            "The repository exists but the push was rejected — it is not usable as a " <>
              "remote yet. #{reason}"
        }
    end
  end

  defp failure(state, reason) do
    %{
      state: state,
      disposition: nil,
      repository: nil,
      commit: nil,
      pushed_at: nil,
      choices: nil,
      reason: reason
    }
  end
end
