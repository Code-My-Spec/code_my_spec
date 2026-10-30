defmodule CodeMySpec.Release.EveryDeploySecretHasASourceTest do
  @moduledoc """
  kamal resolves the secrets a deploy config names from `.kamal/secrets`, not
  from the environment: without the file, the uat deploy failed in migrate
  with "Secret 'KAMAL_REGISTRY_USERNAME' not found, no secret files".
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "every secret a deploy config names is listed in .kamal/secrets" do
    sourced =
      Regex.scan(~r/^([A-Z_]+)=/m, File.read!(Path.join(@root, ".kamal/secrets")))
      |> MapSet.new(fn [_, name] -> name end)

    for config <- ~w(config/deploy.yml config/deploy.uat.yml) do
      named =
        Regex.scan(~r/^\s+- ([A-Z][A-Z_]+)\s*$/m, File.read!(Path.join(@root, config)))
        |> Enum.map(fn [_, name] -> name end)

      assert named != []

      for name <- named do
        assert name in sourced, "#{config} names #{name}, which .kamal/secrets does not source"
      end
    end
  end
end
