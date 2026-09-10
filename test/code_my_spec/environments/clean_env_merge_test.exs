defmodule CodeMySpec.Environments.CleanEnvMergeTest do
  @moduledoc """
  That the scrub does not overwrite what a caller chose.

  `clean_otp_env/0` clears MIX_ENV among the Burrito release variables, and
  `System.cmd` applies duplicate `:env` entries in order — so a caller that
  writes

      [{"MIX_ENV", "test"}] ++ extra ++ clean_otp_env()

  hands the child no MIX_ENV at all. The line naming "test" is dead, and it
  reads like the guarantee it is not.

  That is not hypothetical. The ecto tasks the exunit runner used to invoke
  took MIX_ENV as given, ran in dev, and migrated `code_my_spec_dev` — the
  database every agent shares. `mix test` and `mix spex` survived it only
  because Mix picks the env for those tasks itself, through `preferred_envs`.

  `merge_clean_env/1` is the answer: scrub everything the caller did not name.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments

  test "a chosen variable is not scrubbed out from under the caller" do
    env = Environments.merge_clean_env(env: [{"MIX_ENV", "test"}])[:env]

    assert {"MIX_ENV", "test"} in env

    refute {"MIX_ENV", nil} in env,
           "the scrub cleared the variable the caller chose, so the child gets " <>
             "no MIX_ENV and the line naming `test` does nothing"
  end

  test "a variable the caller did not name is still scrubbed" do
    env = Environments.merge_clean_env(env: [{"MIX_ENV", "test"}])[:env]

    assert {"RELEASE_ROOT", nil} in env,
           "the scrub is what keeps a child `mix` off our Burrito ERTS; " <>
             "naming one variable must not disable the rest"
  end

  # The ordering fact the whole thing rests on, pinned so it is not
  # rediscovered the hard way a third time.
  test "System.cmd applies duplicate env entries in order, last one winning" do
    {set_then_clear, 0} =
      System.cmd("sh", ["-c", "echo [$MIX_ENV]"], env: [{"MIX_ENV", "test"}, {"MIX_ENV", nil}])

    {clear_then_set, 0} =
      System.cmd("sh", ["-c", "echo [$MIX_ENV]"], env: [{"MIX_ENV", nil}, {"MIX_ENV", "test"}])

    assert String.trim(set_then_clear) == "[]"
    assert String.trim(clear_then_set) == "[test]"
  end
end
