defmodule CodeMySpec.CodeMode.Sandbox do
  @moduledoc """
  The VM a script runs in, and everything that stops it running away.

  Four limits, and each one exists because the others do not catch its case.

  `Lua.new/1` sandboxes the dangerous standard library by default — `io.*`,
  `file`, `os.execute`, `os.getenv`, `package`, `require`, `load`, `dofile`. The
  functions are still *present*; calling one raises `"… is sandboxed"`. Worth
  knowing when writing a test: asserting `io == nil` passes against a VM where
  `io.open` works fine, so assert on the call.

  `:max_instructions` bounds CPU. A `while true do end` raises
  `"instruction budget exceeded"` instead of spinning a scheduler, and the
  budget is fresh per evaluation.

  `:max_call_depth` bounds recursion, raising `"stack overflow"`.

  `:max_string_bytes` bounds memory, and it is the one that is easy to miss.
  `string.rep("x", 2^28)` is not an infinite loop and not a blocked host call,
  so neither of the other two sees it — and the library's own default is
  **256 MiB**, a string this process would build and then try to put in an MCP
  response. The ceiling here is in kilobytes: a script's answer goes into an
  agent's context, where anything past a few tens of KB is already useless.

  All four raise **catchable** errors, so a script can `pcall` around its own
  risky work and still return something.

  ## What the limits do not cover

  They bound the VM. They do not bound a host function that blocks, and every
  tool binding is one — they reach the database and, some of them, external
  providers. So evaluation also runs under a wall-clock timeout in a task, and
  the two failures are told apart deliberately: `Task.yield/2` followed by
  `Task.shutdown(:brutal_kill)` collapses them, because the brutal kill on a
  timeout also exits the worker `:killed`, and a CPU-bound loop then reports as
  whichever arrived first.

  ## Tuning

  Every limit is settable under `config :code_my_spec, CodeMySpec.CodeMode` and
  overridable per call. An operator running scripts against a slow database
  wants a longer clock than one on a laptop, and the numbers below are a
  starting point rather than a law.

  It is also the only honest way to specify the timeout. Nothing lets a spec
  make a real tool slow, so a spec that wanted to prove "work past the clock is
  stopped and reported" had no way to; lowering the clock tests the same
  mechanism from the other side.
  """

  @defaults [
    max_instructions: 10_000_000,
    max_call_depth: 200,
    max_string_bytes: 256 * 1024,
    timeout: to_timeout(second: 30)
  ]

  @doc """
  A fresh VM with the limits applied.

  Fresh per evaluation, deliberately: a reused VM carries whatever globals the
  last script assigned, and two agents sharing one would leak state between
  unrelated pieces of work.
  """
  @spec new(keyword()) :: Lua.t()
  def new(opts \\ []) do
    Lua.new(
      max_instructions: limit(opts, :max_instructions),
      max_call_depth: limit(opts, :max_call_depth),
      max_string_bytes: limit(opts, :max_string_bytes)
    )
  end

  @doc "How long an evaluation may take in wall-clock terms."
  @spec timeout(keyword()) :: pos_integer()
  def timeout(opts \\ []), do: limit(opts, :timeout)

  # Call, then configuration, then the default.
  defp limit(opts, key) do
    Keyword.get_lazy(opts, key, fn ->
      :code_my_spec
      |> Application.get_env(CodeMySpec.CodeMode, [])
      |> Keyword.get(key, Keyword.fetch!(@defaults, key))
    end)
  end

  @doc """
  Runs `fun` under the wall-clock timeout.

  `{:error, :timeout}` and `{:error, {:crashed, reason}}` are different answers
  because they are different problems: the first is a script or a provider
  taking too long, the second is a bug. Reporting both as "it failed" is how a
  crash goes unnoticed for a week.
  """
  @spec with_timeout((-> result), keyword()) :: result | {:error, :timeout | {:crashed, term()}}
        when result: term()
  def with_timeout(fun, opts \\ []) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fun)
    await(task, timeout(opts))
  end

  defp await(task, timeout) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, {:crashed, reason}}
    after
      timeout ->
        # Shut down and then drain: the task may have answered in the window
        # between the timeout firing and the kill landing, and reporting a
        # timeout for work that finished is its own kind of wrong.
        Task.shutdown(task, :brutal_kill)
        drain(task)
    end
  end

  defp drain(task) do
    receive do
      {ref, result} when ref == task.ref -> result
      {:DOWN, ref, :process, _pid, _reason} when ref == task.ref -> {:error, :timeout}
    after
      0 -> {:error, :timeout}
    end
  end
end
