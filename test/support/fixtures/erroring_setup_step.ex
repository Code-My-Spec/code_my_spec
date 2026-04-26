defmodule CodeMySpec.SetupFixtures.ErroringStep do
  @moduledoc """
  Test-only stub step whose `evaluate/2` returns `:invalid` and
  `command/2` returns `{:error, :stub_explosion}`.

  Used to exercise the error-propagation path in
  `ProjectSetup.command/2`. Inject via
  `Application.put_env(:code_my_spec, :project_setup_steps, [__MODULE__])`
  (or alongside other steps).
  """

  def evaluate(_scope, _task), do: {:ok, :invalid, "stub is always invalid"}

  def check(_ctx), do: {:invalid, "stub is always invalid"}

  def command(_scope, _task), do: {:error, :stub_explosion}
end
