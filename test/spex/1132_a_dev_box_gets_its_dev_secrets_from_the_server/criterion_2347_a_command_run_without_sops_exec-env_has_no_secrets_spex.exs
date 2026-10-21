defmodule CodeMySpecSpex.Story1132.Criterion2347Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2347 -- A command run without sops exec-env has no secrets.

  Drives a real subprocess (`System.cmd/3`), the one honest way to check
  what a command's own environment actually contains -- reading
  `System.get_env/0` in this test's own process would only prove something
  about the test runner, not about a freshly spawned command the way an
  agent's `mix test` actually runs.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @secret_name "CMS_SPEX_DEV_SECRET"

  spex "A bare command sees none of the project's decrypted secrets", criterion: 2347 do
    scenario "an agent in 'cloud-1' runs `mix test` directly" do
      given_ "the test env holds a secret the agent's shell never set", context do
        refute System.get_env(@secret_name),
               "this test's own environment already carries the secret it is about to " <>
                 "check for, so a pass below would prove nothing"

        {:ok, context}
      end

      when_ "an agent in 'cloud-1' runs a command directly, not through sops exec-env", context do
        {output, 0} = Fixtures.run_cmd("env", [])
        {:ok, Map.put(context, :output, output)}
      end

      then_ "the test env's secrets are not in its environment", context do
        refute context.output =~ @secret_name,
               "a command run without sops exec-env still saw the project's decrypted " <>
                 "secret in its environment"

        {:ok, context}
      end
    end
  end
end
