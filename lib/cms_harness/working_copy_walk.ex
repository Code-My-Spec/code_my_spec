defmodule CmsHarness.WorkingCopyWalk do
  @moduledoc """
  Which working copy a path is inside, by finding the config file that says so.

  Every Claude Code hook payload carries `cwd` — confirmed against the 2.1.237
  binary, whose shared payload base is `{session_id, transcript_path, cwd,
  prompt_id, permission_mode, agent_id, agent_type, effort}`. So a client does
  not have to compute its own identity, interpolate a variable, or ship a shell
  script per platform to do it. It posts the payload; this reads it.

  ## This is not the walk that was removed

  `HooksController` used to say "there is no directory anywhere in this path and
  there is not going to be one", against a previous walk that looked for
  `mix.exs`. Its three objections, and what happens here:

    * *"resolved a hook fired from a subdirectory differently from one fired at
      the root"* — solved. Every subdirectory of a checkout finds the same
      `.cms_harness.json`, because there is exactly one and it is at the root.

    * *"resolved a nested checkout to the outer one"* — solved by the boundary
      below, not by the file. An un-onboarded inner checkout would otherwise
      walk straight past itself into its parent and adopt an identity that is
      not its, which is the same defect wearing a different filename.

    * *"could not tell two copies at the same path on different machines apart"*
      — does not apply. That was the *server* resolving a path it could not see.
      This runs on the machine the path is on, and never leaves it.

  The distinction that makes it safe: a path is used to **locate the file that
  states an identity**, never to select a working copy directly. A path that
  finds no file is a refusal, not a guess — which is the property the removed
  design lacked, where "a wrong path did not fail, it succeeded against the
  wrong disk".

  ## The boundary

  The walk stops at the first directory that looks like the top of a project —
  `.git`, or `mix.exs` — and refuses there if it holds no config. Continuing
  past it is how an un-onboarded checkout inherits its parent's identity, and
  reporting one checkout's work under another's id is the failure this whole
  area keeps producing.

  ### A submodule is not a boundary

  It has a `.git`, so it used to be one, and that wedged the harness. An agent
  that commits to `.code_my_spec` — the normal path; specs, knowledge, rules
  and QA briefs all live there — leaves its shell inside it, every subsequent
  hook payload carries that `cwd`, and the walk refused at the submodule
  forever. Worse than the refusal was its remedy: it named
  `mix cms.harness.onboard` on the submodule, which would register the spec
  repo as a working copy of its own and start tracking its files, problems and
  analysis as a project.

  A submodule is not an independent checkout. It is content *of* the parent,
  committed there as a gitlink, so work done inside it belongs to the parent's
  identity and walking through is correct rather than a leak.

  Git says which it is. A submodule's `.git` is a file whose gitdir has a
  `modules` segment after `.git`; a worktree's does not:

      submodule  gitdir: ../../../../.git/worktrees/wt-name/modules/.code_my_spec
      worktree   gitdir: /Users/…/code_my_spec/.git/worktrees/wt-name
      plain      .git is a directory

  Matched as a path segment after `.git` rather than anywhere in the string, so
  a checkout living under a directory that happens to be called `modules` is
  still a boundary.

  A submodule that genuinely is its own onboarded project is unaffected: it
  holds a `.cms_harness.json`, which is checked before this.
  """

  @config ".cms_harness.json"

  @doc """
  The working copy root containing `path`, or why not.

  `{:ok, root}` — `root` holds a `.cms_harness.json`.
  `{:error, :not_onboarded, dir}` — a project boundary was reached with no
  config in it; `dir` is that boundary, which is what an operator has to
  onboard.
  `{:error, :outside_a_working_copy}` — walked to the filesystem root without
  finding either.
  """
  @spec root_for(String.t()) ::
          {:ok, String.t()}
          | {:error, :not_onboarded, String.t()}
          | {:error, :outside_a_working_copy}
  def root_for(path) when is_binary(path) and path != "" do
    path |> Path.expand() |> climb()
  end

  def root_for(_), do: {:error, :outside_a_working_copy}

  defp climb(dir) do
    cond do
      File.regular?(Path.join(dir, @config)) ->
        {:ok, dir}

      boundary?(dir) ->
        {:error, :not_onboarded, dir}

      true ->
        parent = Path.dirname(dir)
        if parent == dir, do: {:error, :outside_a_working_copy}, else: climb(parent)
    end
  end

  defp boundary?(dir) do
    git_boundary?(Path.join(dir, ".git")) or File.exists?(Path.join(dir, "mix.exs"))
  end

  # A `.git` directory is a plain checkout. A `.git` file is either a worktree
  # or a submodule, and only the worktree is a boundary.
  defp git_boundary?(git) do
    cond do
      File.dir?(git) -> true
      File.regular?(git) -> not submodule?(git)
      true -> false
    end
  end

  defp submodule?(git) do
    case File.read(git) do
      {:ok, contents} -> contents |> gitdir() |> modules_segment?()
      {:error, _reason} -> false
    end
  end

  defp gitdir(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      case String.split(line, "gitdir:", parts: 2) do
        [_before, path] -> String.trim(path)
        _otherwise -> nil
      end
    end)
  end

  # After the `.git` segment, not anywhere in the string: `/srv/modules/app/.git`
  # is somebody's checkout, not a submodule.
  defp modules_segment?(""), do: false

  defp modules_segment?(gitdir) do
    segments = Path.split(gitdir)

    case Enum.find_index(segments, &(&1 == ".git")) do
      nil -> false
      at -> "modules" in Enum.drop(segments, at + 1)
    end
  end
end
