defmodule CodeMySpec.Workspaces.BootStepsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Workspaces.BootSteps

  defp log(lines), do: Enum.map_join(lines, "\n", &"\e[1;36m==> #{&1}\e[0m")

  describe "furthest/1" do
    test "nothing announced yet" do
      assert BootSteps.furthest("") == nil
    end

    test "reads the phase off the container's own markers" do
      assert BootSteps.furthest(log(["Starting Postgres"])) == :starting_database

      assert BootSteps.furthest(log(["Starting Postgres", "Fetching dependencies"])) ==
               :fetching_deps
    end

    test "a reused project sits on the same rung as a generated one" do
      generated = BootSteps.furthest(log(["Generating my_app with mix cms.new"]))
      reused = BootSteps.furthest(log(["Reusing existing project at /workspace/my_app"]))

      assert BootSteps.position(generated) == BootSteps.position(reused)
    end

    test "the bar never walks backwards on interleaved output" do
      out = log(["Starting Postgres", "Setting up the database"]) <> "\nStarting Postgres again\n"

      assert BootSteps.furthest(out) == :migrating
    end

    test "the marker text in ordinary build output does not advance the bar" do
      noise = "compiling Fetching dependencies is not an announcement\n"

      assert BootSteps.furthest(log(["Starting Postgres"]) <> "\n" <> noise) ==
               :starting_database
    end

    test "the full sequence reaches the end" do
      out =
        log([
          "Starting Postgres",
          "Generating my_app with mix cms.new",
          "Fetching dependencies",
          "Setting up the database",
          "Starting the cms harness server on :4003",
          "Starting my_app on :4000"
        ])

      assert BootSteps.furthest(out) == :starting_app
      assert BootSteps.percent(:starting_app) == 100
    end
  end

  describe "percent/1 and label/1" do
    test "progress climbs with the phase" do
      assert BootSteps.percent(nil) == 0
      assert BootSteps.percent(:starting_database) < BootSteps.percent(:fetching_deps)
      assert BootSteps.percent(:fetching_deps) < BootSteps.percent(:starting_app)
    end

    test "every phase has something to show the visitor" do
      for %{key: key} <- BootSteps.steps() do
        assert is_binary(BootSteps.label(key))
        refute BootSteps.label(key) == "Working"
      end
    end
  end
end
