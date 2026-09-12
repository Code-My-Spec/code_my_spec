defmodule CodeMySpec.Provisioning.AGeneratedConfigActuallyParsesTest do
  @moduledoc """
  The parser is exercised against what the generator really writes.

  `DeployConfigParseTest` holds a hand-written fixture labelled "verbatim from a
  generated config". It is not, and has not been for some time: the real
  `kamal_config/5` bakes `host:` as a concrete string at generation time rather
  than leaving an ERB tag to resolve at kamal-invocation time, emits no
  `user: root`, and supports no `CMS_SSH_PORT` (`55498802`).

  That fixture still earns its place — it pins the *parser* against the ERB
  shapes it must tolerate, including ones no current generator emits, and those
  shapes exist in configs generated before the change and in hand-written ones
  like MarketMySpec's. What it cannot do is what its label claimed: show that
  today's generator produces something this parser can read.

  Both claims matter, and they are different tests. This is the second one, and
  it is the one that would have caught the original defect —
  `config_targets_this_project/2` answers a failed parse with `:ok`, so a
  generator drifting away from its parser looks exactly like a passing check.

  Deliberately asserts nothing about whether `proxy.host` should be an ERB tag
  or a baked string. That is the open design question on `55498802` — the
  registry address went the same way in `84f49fd59`, suggesting it is
  intentional — and a test that pinned either answer would decide it by
  accident.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.Provisioning.Steps

  defp generated(path) do
    {^path, contents} =
      [app: "myapp", host: "example.com", registry: "registry.example.com", owner: "acme"]
      |> DeployArtifacts.files()
      |> Enum.find(fn {name, _contents} -> name == path end)

    contents
  end

  describe "the config this generator writes today" do
    test "config/deploy.yml parses" do
      assert {:ok, config} = Steps.parse_deploy_config(generated("config/deploy.yml")),
             "the generator and the parser have drifted apart — and a failed parse is " <>
               "answered with :ok by config_targets_this_project/2, so nothing else says so"

      assert config["service"]
    end

    test "config/deploy.uat.yml parses too" do
      assert {:ok, config} = Steps.parse_deploy_config(generated("config/deploy.uat.yml"))
      assert config["service"]
    end

    # The ssh block was absent entirely when `55498802` was filed, so a key
    # delivered onto the builder was never read. `2bd1f3d72` added it, guarded
    # by CMS_SSH_KEY_PATH — this holds it there and, more to the point, holds it
    # *parseable*, which is the half the guard's ERB conditional puts at risk.
    test "the ssh block survives the parse rather than being stripped with its tag" do
      config = generated("config/deploy.yml")

      assert config =~ "ssh:",
             "a generated config with no ssh block means a delivered key is never read"

      assert {:ok, parsed} = Steps.parse_deploy_config(config)
      assert is_map(parsed["ssh"]), "the ssh block parsed away to nothing"
    end
  end
end
