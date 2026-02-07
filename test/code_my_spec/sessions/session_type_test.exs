defmodule CodeMySpec.Sessions.SessionTypeTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.AgentTasks

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp valid_module_atoms do
    [
      AgentTasks.ComponentSpec,
      AgentTasks.ComponentCode,
      AgentTasks.ComponentTest,
      AgentTasks.ContextSpec,
      AgentTasks.ContextComponentSpecs,
      AgentTasks.ContextImplementation,
      AgentTasks.ContextDesignReview,
      AgentTasks.ArchitectureDesign,
      AgentTasks.ArchitectureReview,
      AgentTasks.ProjectSetup,
      AgentTasks.WriteBddSpecs
    ]
  end

  defp valid_string_names do
    [
      "ComponentSpec",
      "ComponentCode",
      "ComponentTest",
      "ContextSpec",
      "ContextComponentSpecs",
      "ContextImplementation",
      "ContextDesignReview",
      "ArchitectureDesign",
      "ArchitectureReview",
      "ProjectSetup",
      "WriteBddSpecs"
    ]
  end

  defp invalid_types do
    [
      "InvalidType",
      "UnknownTask",
      "NotAnAgentTask",
      "",
      123,
      nil,
      %{},
      [],
      :invalid_atom,
      SomeOtherModule
    ]
  end

  # ============================================================================
  # cast/1 Tests
  # ============================================================================

  describe "cast/1" do
    test "returns module atom for valid string name (e.g. \"ComponentSpec\" → AgentTasks.ComponentSpec)" do
      assert {:ok, AgentTasks.ComponentSpec} = SessionType.cast("ComponentSpec")
      assert {:ok, AgentTasks.ComponentCode} = SessionType.cast("ComponentCode")
      assert {:ok, AgentTasks.ComponentTest} = SessionType.cast("ComponentTest")
      assert {:ok, AgentTasks.ContextSpec} = SessionType.cast("ContextSpec")
      assert {:ok, AgentTasks.ContextComponentSpecs} = SessionType.cast("ContextComponentSpecs")
      assert {:ok, AgentTasks.ContextImplementation} = SessionType.cast("ContextImplementation")
      assert {:ok, AgentTasks.ContextDesignReview} = SessionType.cast("ContextDesignReview")
      assert {:ok, AgentTasks.ArchitectureDesign} = SessionType.cast("ArchitectureDesign")
      assert {:ok, AgentTasks.ArchitectureReview} = SessionType.cast("ArchitectureReview")
      assert {:ok, AgentTasks.ProjectSetup} = SessionType.cast("ProjectSetup")
      assert {:ok, AgentTasks.WriteBddSpecs} = SessionType.cast("WriteBddSpecs")
    end

    test "returns module atom for valid atom" do
      for module <- valid_module_atoms() do
        assert {:ok, ^module} = SessionType.cast(module)
      end
    end

    test "returns :error for unknown type" do
      for invalid <- invalid_types() do
        assert :error = SessionType.cast(invalid)
      end
    end
  end

  # ============================================================================
  # mapper/0 Tests
  # ============================================================================

  describe "mapper/0" do
    test "maps \"ComponentSpec\" to AgentTasks.ComponentSpec" do
      mapper = SessionType.mapper()
      assert mapper["ComponentSpec"] == AgentTasks.ComponentSpec
    end

    test "includes all valid agent task types" do
      mapper = SessionType.mapper()

      # Verify all expected string names are present
      for name <- valid_string_names() do
        assert Map.has_key?(mapper, name), "Expected mapper to include key: #{name}"
      end

      # Verify all expected module atoms are present as values
      mapper_values = Map.values(mapper)
      for module <- valid_module_atoms() do
        assert module in mapper_values, "Expected mapper to include module: #{inspect(module)}"
      end

      # Verify the mapper has exactly the expected number of entries
      assert map_size(mapper) == length(valid_module_atoms())
    end
  end
end
