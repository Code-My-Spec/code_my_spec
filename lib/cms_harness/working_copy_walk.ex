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
  """

  @config ".cms_harness.json"
  @boundaries [".git", "mix.exs"]

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

  defp boundary?(dir), do: Enum.any?(@boundaries, &File.exists?(Path.join(dir, &1)))
end
