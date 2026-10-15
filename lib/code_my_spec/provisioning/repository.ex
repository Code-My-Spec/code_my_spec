defmodule CodeMySpec.Provisioning.Repository do
  @moduledoc """
  The project's Git remote — created or adopted through the user's own GitHub
  OAuth grant.

  - **An OAuth App, not a GitHub App.** The `repo` scope grants everything
    the user can reach, so choosing which repository is our job
    (`GitHub.list_repositories/2`), and the grant is revocable only wholesale.
  - **Adoption is not collision.** `adopt: true` takes the user's chosen
    repository and creates nothing. An existing repository the user did not
    choose returns `{:name_taken, ...}` with both choices; neither is taken
    on their behalf.
  - **No credential fallback.** A revoked grant returns
    `{:error, :github_not_connected}`; a platform token or local `gh` would
    create the repository under the wrong account and look like success.
  - **Done is a push.** `run/4` completes only when a push lands and records
    the commit: a read-only grant, an archived repo or a protected branch all
    leave a repository that exists but is not a remote.

  See knowledge/provisioning, "Repository".
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.GitHub
  alias CodeMySpec.Users.Scope

  # The generated CI template writes this placeholder literally: the owner is
  # unknown until a repository exists, so `push/3` substitutes it.
  @ci_workflow_path ".github/workflows/build.yml"
  @github_owner_placeholder "<GITHUB_OWNER>"

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
  defdelegate default_name(project), to: CodeMySpec.Projects.Project, as: :slug

  @doc """
  Create the repository, or adopt one the user has chosen.

  `opts`:
    * `:name` — overrides `default_name/1`
    * `:owner` — the account login; required to check for an existing repo
    * `:org` — create inside this organisation instead of the personal account
    * `:adopt` — `true` when the user has chosen the existing repository
    * `:private` — defaults to `true`
  """
  @spec ensure(Scope.t(), map(), keyword()) ::
          {:ok, disposition(), map()}
          | {:name_taken, map()}
          | {:error, :github_not_connected}
          | {:error, term()}
  def ensure(%Scope{} = scope, project, opts \\ []) do
    name = Keyword.get(opts, :name) || default_name(project)
    owner = Keyword.get(opts, :owner) || authenticated_owner(scope)

    case existing(scope, owner, name) do
      {:ok, repo} -> resolve_existing(repo, name, opts)
      {:error, :not_found} -> create(scope, name, opts)
      {:error, _} = error -> error
    end
  end

  # Whose account to look in when the caller did not say; without it the
  # ordinary path created a duplicate and GitHub's 422 was the first sign.
  defp authenticated_owner(scope) do
    case GitHub.authenticated_login(scope) do
      {:ok, login} -> login
      _ -> nil
    end
  end

  # Still nil when GitHub will not say who the token is: let GitHub arbitrate
  # on create rather than guessing an account.
  defp existing(_scope, nil, _name), do: {:error, :not_found}
  defp existing(scope, owner, name), do: GitHub.get_repository(scope, owner, name)

  defp resolve_existing(repo, _name, opts) do
    if Keyword.get(opts, :adopt, false) do
      {:ok, :adopted, repo}
    else
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

  # No `auto_init`: GitHub's README commit and our first commit would be
  # unrelated histories, and the push would be rejected as non-fast-forward.
  defp create(scope, name, opts) do
    attrs = %{
      name: name,
      private: Keyword.get(opts, :private, true)
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

  Inits when absent (a just-generated project has no git yet), commits when
  there is no HEAD, and sets the remote whether or not `origin` exists. Every
  git invocation captures stderr, so a failure says more than its exit code.
  """
  @spec push(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def push(env, remote_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    git = Keyword.get(opts, :git_bin, "git")
    run = fn args -> Environments.cmd(env, git, args, stderr_to_stdout: true) end

    with :ok <- ensure_repo(run, branch),
         :ok <- patch_ci_owner(env, opts),
         :ok <- ensure_commit(run),
         :ok <- commit_owner_patch(run),
         :ok <- set_remote(run, remote_url),
         :ok <- push_remote(run, branch, opts),
         {sha, 0} <- run.(["rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, "git exited #{status}: #{String.trim(to_string(output))}"}
    end
  end

  # Before `ensure_commit` so a fresh repository's initial commit includes the
  # substitution. An already-pushed repository gets it committed by
  # `commit_owner_patch/1`. No-op without `:owner` or without the file.
  defp patch_ci_owner(env, opts) do
    case Keyword.get(opts, :owner) do
      owner when is_binary(owner) and owner != "" -> substitute_owner(env, owner)
      _ -> :ok
    end
  end

  defp substitute_owner(env, owner) do
    case Environments.read_file(env, @ci_workflow_path) do
      {:ok, content} ->
        if String.contains?(content, @github_owner_placeholder) do
          write_owner(env, String.replace(content, @github_owner_placeholder, owner))
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp write_owner(env, content) do
    case Environments.write_file(env, @ci_workflow_path, content) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> {:error, "could not patch #{@ci_workflow_path}: #{inspect(other)}"}
    end
  end

  # `ensure_commit/1` commits only when there is no HEAD, so an existing
  # repository would leave the substitution uncommitted. Scoped to the one
  # path, not `git add -A`.
  defp commit_owner_patch(run) do
    case run.(["status", "--porcelain", "--", @ci_workflow_path]) do
      {"", 0} ->
        :ok

      {_dirty, 0} ->
        with {_, 0} <- run.(["add", "--", @ci_workflow_path]),
             {_, 0} <- run.(["commit", "-m", "Set GHCR image owner in CI workflow"]) do
          :ok
        else
          {output, status} ->
            {:error,
             "could not commit the CI workflow owner fix (#{status}): #{String.trim(output)}"}
        end

      {output, status} ->
        {:error,
         "could not check #{@ci_workflow_path} status (#{status}): #{String.trim(output)}"}
    end
  end

  # `push_remote: false` skips only the network round-trip: git is a
  # subprocess no cassette intercepts, so a replay would push to a repository
  # that existed only during recording. Production never skips it.
  defp push_remote(run, branch, opts) do
    case Keyword.get(opts, :push_remote, true) do
      false ->
        :ok

      _ ->
        case run.(["push", "-u", "origin", branch]) do
          {_, 0} -> :ok
          {output, status} -> {output, status}
        end
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

  # `git push` with no commit fails in a way that reads like a permissions
  # problem.
  defp ensure_commit(run) do
    case run.(["rev-parse", "HEAD"]) do
      {_, 0} ->
        :ok

      _ ->
        with {_, 0} <- run.(["add", "-A"]),
             {_, 0} <- run.(["commit", "-m", "Initial commit"]) do
          :ok
        else
          {output, status} ->
            {:error, "could not create the initial commit (#{status}): #{String.trim(output)}"}
        end
    end
  end

  # An existing origin pointing at the same repository is a retry; one
  # pointing elsewhere means the working directory belongs to another
  # repository, and repointing would push its whole history. Refuse.
  defp set_remote(run, url) do
    case run.(["remote", "add", "origin", url]) do
      {_, 0} ->
        :ok

      _ ->
        case run.(["remote", "get-url", "origin"]) do
          {existing, 0} ->
            adopt_or_refuse(run, url, String.trim(existing))

          _ ->
            replace_remote(run, url)
        end
    end
  end

  defp adopt_or_refuse(run, url, existing) do
    if same_repo?(existing, url) do
      replace_remote(run, url)
    else
      {:error,
       "origin already points at #{existing}, not #{url} — refusing to repoint it. " <>
         "This directory belongs to another repository; check the working directory."}
    end
  end

  # SSH and HTTPS forms of the same repository are the same remote, and a
  # retry may arrive by either.
  defp same_repo?(a, b), do: normalize_remote(a) == normalize_remote(b)

  defp normalize_remote(url) do
    url
    |> String.trim()
    |> String.replace(~r{^git@([^:]+):}, "https://\\1/")
    |> String.replace(~r{\.git$}, "")
    |> String.downcase()
  end

  defp replace_remote(run, url) do
    case run.(["remote", "set-url", "origin", url]) do
      {_, 0} -> :ok
      {output, status} -> {:error, "could not set the remote (#{status}): #{String.trim(output)}"}
    end
  end

  @doc """
  Ensure the repository exists and prove it by pushing to it.

  Returns a result whose `pushed_at` is set only when a push actually landed.
  There is no field claiming success independently of the proof.
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
    # The repository's own owner: under `opts[:org]` that is the org, not the
    # authenticated user.
    opts = Keyword.put(opts, :owner, repo_owner_login(repo))

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

  defp repo_owner_login(%{"owner" => %{"login" => login}})
       when is_binary(login) and login != "",
       do: login

  defp repo_owner_login(_repo), do: nil
end
