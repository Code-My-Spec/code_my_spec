defmodule CodeMySpec.LandingHold do
  @moduledoc """
  Where the landing-hold marker lives in a checkout (issue 725a1d32, a4753b66).

  A landing leaves `landing_hold` in the checkout's git directory, so it never
  dirties the tree, and `CodeMySpecWeb.Plugs.HoldDuringLanding` holds requests
  while it is fresh. The git directory is `.git` in an ordinary checkout and
  somewhere else in a worktree, where `.git` is a *file* reading
  `gitdir: <path>`: a path built as `<root>/.git/landing_hold` is "Not a
  directory" there, and `rm -f` of it exits 1, which stopped every worktree
  copy's `serve` and `reload` recipes.

  The recipes ask git (`git rev-parse --git-path landing_hold`); this answers the
  same question without running it, for the merge that writes the marker and the
  plug that reads it, so all three agree.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @marker "landing_hold"

  @doc "The marker's path for the checkout at `root`."
  @spec marker_path(String.t()) :: String.t()
  def marker_path(root), do: Path.join(git_dir(root), @marker)

  @doc """
  The git directory of the checkout at `root`: its `.git` directory, or where a
  worktree's `.git` file points.
  """
  @spec git_dir(String.t()) :: String.t()
  def git_dir(root) do
    dot_git = Path.join(root, ".git")

    case File.read(dot_git) do
      {:ok, "gitdir: " <> target} -> target |> String.trim() |> Path.expand(root)
      _a_directory_or_not_there -> dot_git
    end
  end
end
