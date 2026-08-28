defmodule CodeMySpec.Agents.PlatformCredentialTest do
  @moduledoc """
  Story 875. Intake ends with the visitor talking to their project's agent, and
  someone who signed up ninety seconds ago has connected no provider. Making
  them connect one there puts an OAuth detour in the exact stretch the flow
  exists to make seamless.

  So the first conversation runs on our credential — and the tests that matter
  are the ones about when it does *not*. This spends real money on people who
  may never come back, and the funnel leaks by design.
  """
  # Sync: reads application config that other tests must not see changed.
  use ExUnit.Case, async: false

  alias CodeMySpec.Agents.Credential

  setup do
    prior = Application.get_env(:code_my_spec, Credential)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore(config), do: Application.put_env(:code_my_spec, Credential, config)

  test "unset, there is no platform credential" do
    Application.delete_env(:code_my_spec, Credential)

    assert {:error, :not_connected} = Credential.platform_credential("anthropic"),
           "an unset configuration handed out a credential, so a deployment that " <>
             "never chose to pay for visitors' conversations would start paying for " <>
             "them. `Agents.turn_allowance/2` bounds it once switched on, but a cap " <>
             "makes the spend bounded rather than free, so the default is still the " <>
             "behaviour that costs nothing."
  end

  test "blank is the same as unset" do
    Application.put_env(:code_my_spec, Credential, platform_api_key: "   ")

    assert {:error, :not_connected} = Credential.platform_credential("anthropic")
  end

  test "configured, it is the shape the agent reads" do
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform")

    assert {:ok, credential} = Credential.platform_credential("anthropic")

    assert credential == %{"type" => "api_key", "key" => "sk-platform"},
           "the credential carries a field the agent does not read, or is missing " <>
             "one it does. Pi holds exactly two shapes and this is the api_key one."
  end
end
