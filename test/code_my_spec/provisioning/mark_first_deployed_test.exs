defmodule CodeMySpec.Provisioning.MarkFirstDeployedTest do
  @moduledoc """
  `first_deployed_at` is set once and never touched again — that is the
  whole point of it. `Deploy.run/3` reads it to tell "nothing has ever
  gone live here" apart from "a health check is protecting something
  real", and a value that could move backwards to `nil`, or forwards past
  its first setting, would make that answer unreliable in exactly the way
  kamal's own env-file side effect already was.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.EnvironmentRepository

  setup do
    scope = full_scope_fixture()
    [environment] = EnvironmentRepository.list(scope) |> Enum.filter(&(&1.name == "uat"))
    %{scope: scope, environment: environment}
  end

  test "an environment nobody has deployed starts with no first_deployed_at", %{
    environment: environment
  } do
    assert environment.first_deployed_at == nil
  end

  test "records the first deploy", %{scope: scope} do
    :ok = EnvironmentRepository.mark_first_deployed(scope, "uat")

    assert %DateTime{} = EnvironmentRepository.get(scope, "uat").first_deployed_at
  end

  test "a second call does not move the timestamp", %{scope: scope} do
    :ok = EnvironmentRepository.mark_first_deployed(scope, "uat")
    first = EnvironmentRepository.get(scope, "uat").first_deployed_at

    :ok = EnvironmentRepository.mark_first_deployed(scope, "uat")
    second = EnvironmentRepository.get(scope, "uat").first_deployed_at

    assert DateTime.compare(first, second) == :eq
  end

  test "marking one environment leaves a sibling untouched", %{scope: scope} do
    :ok = EnvironmentRepository.mark_first_deployed(scope, "uat")

    assert EnvironmentRepository.get(scope, "prod").first_deployed_at == nil
  end
end
