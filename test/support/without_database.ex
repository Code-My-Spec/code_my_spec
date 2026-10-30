defmodule CodeMySpecTest.WithoutDatabase do
  @moduledoc """
  Run a function where the database cannot be reached: a process the sandbox
  has not allowed, so any query raises. What a harness, which holds no
  database, can compute.
  """

  import ExUnit.Assertions

  @doc "`{:ok, result}`, or `{:raised, exception}` when `fun` reached for the database."
  @spec run((-> term())) :: {:ok, term()} | {:raised, Exception.t()}
  def run(fun) do
    parent = self()

    spawn(fn ->
      result =
        try do
          {:ok, fun.()}
        rescue
          error -> {:raised, error}
        end

      send(parent, {__MODULE__, result})
    end)

    assert_receive {__MODULE__, result}, 5_000
    result
  end
end
