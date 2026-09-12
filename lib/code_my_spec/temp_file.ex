defmodule CodeMySpec.TempFile do
  @moduledoc """
  Paths under the shared temp directory that no other process will pick.

  `System.unique_integer/1` is unique **within one BEAM**. `System.tmp_dir!/0`
  is shared by every process on the machine. Combining them gives a name that
  looks unique and is not: two OS processes each start the counter fresh, so
  two suites — or a suite and the harness's analyzers — generate
  `compile_diagnostics_7.jsonl` at the same time and one reads the other's file.

  That is not hypothetical and it is not only a test problem. It presented as
  `analysis_test.exs:173` failing with "diagnostics came back for a project with
  no :diagnostics compiler", three times in one night, on a project that has no
  compiler capable of writing them. The diagnostics it read belonged to another
  process's project. In production the same collision means one project's
  analyzer reporting another project's problems.

  It is also the third instance of one bug class here. Issue `0bc611c9` records
  the other two: a repo pool naming directories from a per-GenServer counter so
  two suites both handed out `pool_code_repo_1`, and a fake upstream picking its
  port with `Enum.random/1`. Same mistake each time — a name unique in one
  process treated as unique on the machine.

  So the token carries the OS pid as well, which is unique across processes by
  definition, plus random bytes so a pid recycled after a crash cannot collide
  with its predecessor's leftovers.

  A leaf boundary of its own, like `Environments` and `Repo`, because the
  callers that most need it are outside `CodeMySpec`: the spex suite and the
  harness's test support both build temp paths, and both are top-level
  boundaries that cannot reach in here. The alternative was each of them
  keeping its own copy of the token — which is how there came to be three
  instances of the bug in the first place.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @doc """
  A temp file path: `<tmp>/<prefix>_<token><suffix>`.

      iex> path = CodeMySpec.TempFile.path("compile_diagnostics", ".jsonl")
      iex> String.ends_with?(path, ".jsonl")
      true

      iex> CodeMySpec.TempFile.path("x") == CodeMySpec.TempFile.path("x")
      false
  """
  @spec path(String.t(), String.t()) :: String.t()
  def path(prefix, suffix \\ "") do
    Path.join(System.tmp_dir!(), "#{prefix}_#{token()}#{suffix}")
  end

  @doc """
  A temp directory path, hyphenated to match the existing `cms-ssh-…` style.

  Does not create it — callers that need it on disk still `mkdir_p`, and callers
  handing the path to something that creates it should not.
  """
  @spec dir(String.t()) :: String.t()
  def dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{token()}")
  end

  @doc """
  Remove a temp file, quietly, if it exists.

  Was two copies (`CodeMySpec.StaticAnalysis.Analyzers.Credo` and `.Sobelow`),
  one of them missing the tmp-dir boundary check the other had. One
  implementation now, with the check: only ever removes a path actually under
  `System.tmp_dir!/0`, so a caller that passes something else by mistake
  cannot turn this into an arbitrary `rm`.

  `rescue`s because deleting a file that raced another cleanup, or sits on a
  filesystem this process can't touch, is not this caller's problem — the
  temp file is scratch space, not state anything depends on existing.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(path) when is_binary(path) do
    tmp_dir = System.tmp_dir!()

    if String.starts_with?(Path.expand(path), tmp_dir) and File.exists?(path) do
      File.rm(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  # The OS pid makes this unique across processes; `unique_integer` keeps it
  # unique within one; the random suffix covers a recycled pid meeting files an
  # earlier incarnation left behind. Any two of the three would nearly do — all
  # three cost nothing and this has now been got wrong three times.
  defp token do
    random = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    "#{System.pid()}_#{System.unique_integer([:positive])}_#{random}"
  end
end
