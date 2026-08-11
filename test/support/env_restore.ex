defmodule CodeMySpecTest.EnvRestore do
  @moduledoc """
  Putting an OS environment variable back the way it was.

  "Restore it, or delete it if it was never set" is a branch, and a branch
  inside a `_test.exs` is what `NoControlFlowInTests` exists to stop — a test
  reacting to state instead of controlling it. Here the state genuinely belongs
  to the OS and the branch is cleanup rather than assertion, so it lives out
  here where the rule does not apply and the test reads as one call.

  A var that was unset must go back to unset rather than to `""`: those are
  different to `System.get_env/1`, and the difference is exactly what a test
  about environment handling is usually about.
  """

  @spec restore(String.t(), String.t() | nil) :: :ok
  def restore(name, nil), do: System.delete_env(name)
  def restore(name, value), do: System.put_env(name, value)
end
