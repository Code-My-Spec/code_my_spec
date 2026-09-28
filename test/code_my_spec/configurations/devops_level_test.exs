defmodule CodeMySpec.Configurations.DevopsLevelTest do
  @moduledoc """
  One reading of a project's devops level. A row predating the column loads
  `nil`; the graph kept `deploy` for it while `devops_status` called it off.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Configurations.ProjectConfiguration

  test "a legacy nil reads as off" do
    assert ProjectConfiguration.devops_level(%ProjectConfiguration{devops: nil}) == :off
  end

  test "no configuration reads as off" do
    assert ProjectConfiguration.devops_level(nil) == :off
  end

  test "a set level is itself" do
    assert ProjectConfiguration.devops_level(%ProjectConfiguration{devops: :uat}) == :uat
  end
end
