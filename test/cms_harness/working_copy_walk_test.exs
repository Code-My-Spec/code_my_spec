defmodule CmsHarness.WorkingCopyWalkTest do
  @moduledoc """
  Finding a working copy from a path, without repeating the walk that was
  removed.

  `HooksController` records why the previous one went: it looked for `mix.exs`,
  so it "resolved a hook fired from a subdirectory differently from one fired at
  the root" and "resolved a nested checkout to the outer one". These assert both
  are gone — the first because the config file is unique and at the root, the
  second because the walk stops at a project boundary rather than climbing
  through it.

  The nested case is the one worth having a test for. A file-based walk fixes
  the subdirectory problem by itself and does *nothing* for nesting: an
  un-onboarded inner checkout walks straight past itself into its parent and
  reports its work under an id that is not its own. That is the same defect the
  old walk had, wearing a different filename.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.WorkingCopyWalk

  defp tmp do
    dir = Path.join(System.tmp_dir!(), "walk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp onboard(dir) do
    File.write!(
      Path.join(dir, ".cms_harness.json"),
      ~s({"harness_id":"id-#{Path.basename(dir)}"})
    )

    dir
  end

  defp repo(dir) do
    File.mkdir_p!(Path.join(dir, ".git"))
    dir
  end

  # The shapes git actually writes, copied off disk on 2026-08-29 rather than
  # invented: a submodule of a plain checkout, a submodule of a worktree, and a
  # worktree. The `modules` segment is the only thing separating the first two
  # from the third.
  defp submodule(dir, gitdir \\ "../../.git/modules/.code_my_spec") do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: #{gitdir}\n")
    dir
  end

  defp worktree(dir, gitdir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: #{gitdir}\n")
    dir
  end

  test "a subdirectory resolves to the same root as the root itself" do
    root = tmp() |> repo() |> onboard()
    deep = Path.join([root, "lib", "code_my_spec", "files"])
    File.mkdir_p!(deep)

    assert {:ok, ^root} = WorkingCopyWalk.root_for(root)

    assert {:ok, ^root} = WorkingCopyWalk.root_for(deep),
           "a hook fires wherever the agent happens to be; that must not change the answer"
  end

  test "an un-onboarded checkout nested in an onboarded one refuses" do
    outer = tmp() |> repo() |> onboard()
    inner = Path.join(outer, "vendor/thing")
    File.mkdir_p!(Path.join(inner, ".git"))

    assert {:error, :not_onboarded, ^inner} = WorkingCopyWalk.root_for(inner), """
    The inner checkout adopted the outer one's identity.

    That is the defect the previous walk was removed for. A file-based walk does
    not fix it on its own — only stopping at the project boundary does. Reporting
    one checkout's work under another's id is the failure this area keeps
    producing.
    """
  end

  test "an onboarded checkout nested in another resolves to itself" do
    outer = tmp() |> repo() |> onboard()
    inner = Path.join(outer, "vendor/thing")
    File.mkdir_p!(inner)
    repo(inner)
    onboard(inner)

    assert {:ok, ^inner} = WorkingCopyWalk.root_for(inner),
           "the innermost config wins — it is the copy you are actually in"
  end

  test "a project with no config names itself as the thing to onboard" do
    root = tmp() |> repo()

    assert {:error, :not_onboarded, ^root} = WorkingCopyWalk.root_for(root),
           "the refusal has to name the directory an operator would run onboard in"
  end

  test "mix.exs is a boundary too, for a checkout that is not a git repo" do
    root = tmp()
    File.write!(Path.join(root, "mix.exs"), "defmodule X do end")

    assert {:error, :not_onboarded, ^root} = WorkingCopyWalk.root_for(root)
  end

  describe "a submodule is content of its parent, not a checkout of its own" do
    test "work inside it belongs to the parent" do
      root = tmp() |> repo() |> onboard()
      sub = submodule(Path.join(root, ".code_my_spec"))

      assert {:ok, ^root} = WorkingCopyWalk.root_for(sub), """
      The submodule refused, and this is the failure that wedged the harness.

      Committing to `.code_my_spec` is the normal path — specs, knowledge, rules
      and QA briefs live there. An agent that does it leaves its shell inside,
      every later hook payload carries that cwd, and every stop refused. The
      remedy the refusal named was `onboard` on the submodule, which would have
      registered the spec repo as a project.
      """
    end

    test "and so does work in a directory under it" do
      root = tmp() |> repo() |> onboard()
      sub = submodule(Path.join(root, ".code_my_spec"))
      deep = Path.join([sub, "knowledge", "code_mode"])
      File.mkdir_p!(deep)

      assert {:ok, ^root} = WorkingCopyWalk.root_for(deep)
    end

    test "a submodule of a worktree resolves the same way" do
      root = tmp() |> repo() |> onboard()

      sub =
        submodule(
          Path.join(root, ".code_my_spec"),
          "../../../../.git/worktrees/phx-new-generator/modules/.code_my_spec"
        )

      assert {:ok, ^root} = WorkingCopyWalk.root_for(sub),
             "the real shape this was reported against"
    end

    test "but one that is its own onboarded project still wins" do
      root = tmp() |> repo() |> onboard()
      sub = root |> Path.join("vendor/thing") |> submodule() |> onboard()

      assert {:ok, ^sub} = WorkingCopyWalk.root_for(sub),
             "the config is checked before the boundary, so this never reached the change"
    end
  end

  describe "what is still a boundary" do
    test "a worktree, whose .git is also a file" do
      root = tmp() |> repo() |> onboard()
      wt = worktree(Path.join(root, "wt"), "/somewhere/.git/worktrees/wt")

      assert {:error, :not_onboarded, ^wt} = WorkingCopyWalk.root_for(wt), """
      A worktree is an independent checkout and must not inherit an identity.
      Its `.git` is a file too, which is why "the file is a file" was never the
      discriminator — the `modules` segment is.
      """
    end

    test "a checkout that merely lives under a directory named modules" do
      root = tmp() |> repo() |> onboard()
      inner = worktree(Path.join(root, "inner"), "/srv/modules/app/.git")

      assert {:error, :not_onboarded, ^inner} = WorkingCopyWalk.root_for(inner),
             "`modules` counts only as a segment after `.git`, not anywhere in the string"
    end

    test "a .git file that says nothing useful" do
      root = tmp() |> repo() |> onboard()
      inner = Path.join(root, "inner")
      File.mkdir_p!(inner)
      File.write!(Path.join(inner, ".git"), "")

      assert {:error, :not_onboarded, ^inner} = WorkingCopyWalk.root_for(inner),
             "unreadable provenance is not evidence of a submodule; refuse rather than adopt"
    end
  end

  test "a path outside any project says so rather than guessing" do
    assert {:error, :outside_a_working_copy} = WorkingCopyWalk.root_for(tmp())
  end

  test "a blank or missing path is not an identity" do
    assert {:error, :outside_a_working_copy} = WorkingCopyWalk.root_for(nil)
    assert {:error, :outside_a_working_copy} = WorkingCopyWalk.root_for("")
  end
end
