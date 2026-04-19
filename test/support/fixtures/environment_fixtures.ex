defmodule CodeMySpec.EnvironmentFixtures do
  @moduledoc """
  Test helpers for creating Environment instances.

  Environments are created via the `CodeMySpec.Environments` context so the
  real dispatcher is exercised. Each fixture returns a fully-initialized
  `%Environment{}` struct ready to be attached to a scope.
  """

  alias CodeMySpec.Environments

  @doc """
  Generate an in-memory environment for tests.

  Each call creates a fresh `:memory` environment backed by its own Agent
  with a unique `working_dir` under `/memfs/`. Nothing touches the real
  filesystem — all reads/writes go through the Agent's state.

  ## Options

  - `:working_dir` — override the default unique `/memfs/env-N` path. Pass
    the same value across multiple calls to share state (rare — usually
    tests want isolation).
  - `:metadata` — arbitrary map stored on the env for test bookkeeping.

  ## Examples

      iex> env = memory_environment_fixture()
      iex> env.type
      :memory

      iex> env = memory_environment_fixture(working_dir: "/memfs/my-test")
      iex> env.cwd
      "/memfs/my-test"
  """
  @spec memory_environment_fixture(keyword()) :: Environments.Environment.t()
  def memory_environment_fixture(opts \\ []) do
    working_dir =
      Keyword.get(opts, :working_dir, "/memfs/env-#{System.unique_integer([:positive])}")

    {:ok, env} =
      Environments.create(:memory,
        working_dir: working_dir,
        metadata: Keyword.get(opts, :metadata, %{})
      )

    env
  end
end
