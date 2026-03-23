defmodule CodeMySpec.Sessions.SessionTypeTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions.SessionType

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp valid_module_atoms do
    [
      AgentTasks.ArchitectureDesign,
      AgentTasks.ArchitectureReview,
      AgentTasks.ComponentCode,
      AgentTasks.ComponentSpec,
      AgentTasks.ComponentTest,
      AgentTasks.ContextComponentSpecs,
      AgentTasks.ContextDesignReview,
      AgentTasks.ContextImplementation,
      AgentTasks.ContextSpec,
      AgentTasks.DesignUi,
      AgentTasks.DevelopComponent,
      AgentTasks.DevelopContext,
      AgentTasks.DevelopController,
      AgentTasks.DevelopLiveContext,
      AgentTasks.DevelopLiveView,
      AgentTasks.FixAllBddSpecs,
      AgentTasks.FixBddSpecs,
      AgentTasks.FixIssues,
      AgentTasks.LinkStoryComponent,
      AgentTasks.LiveContextSpec,
      AgentTasks.LiveViewSpec,
      AgentTasks.ProjectSetup,
      AgentTasks.QaApp,
      AgentTasks.QaIntegrationPlan,
      AgentTasks.QaJourneyExecute,
      AgentTasks.QaJourneyPlan,
      AgentTasks.QaJourneyWallaby,
      AgentTasks.QaPreflight,
      AgentTasks.QaSetup,
      AgentTasks.QaStory,
      AgentTasks.RefactorModule,
      AgentTasks.ResearchTopic,
      AgentTasks.StartImplementation,
      AgentTasks.TechnicalStrategy,
      AgentTasks.TriageIssues,
      AgentTasks.WriteBddSpecs
    ]
  end

  defp valid_string_names do
    [
      "ArchitectureDesign",
      "ArchitectureReview",
      "ComponentCode",
      "ComponentSpec",
      "ComponentTest",
      "ContextComponentSpecs",
      "ContextDesignReview",
      "ContextImplementation",
      "ContextSpec",
      "DesignUi",
      "DevelopComponent",
      "DevelopContext",
      "DevelopController",
      "DevelopLiveContext",
      "DevelopLiveView",
      "FixAllBddSpecs",
      "FixBddSpecs",
      "FixIssues",
      "LinkStoryComponent",
      "LiveContextSpec",
      "LiveViewSpec",
      "ProjectSetup",
      "QaApp",
      "QaIntegrationPlan",
      "QaJourneyExecute",
      "QaJourneyPlan",
      "QaJourneyWallaby",
      "QaPreflight",
      "QaSetup",
      "QaStory",
      "RefactorModule",
      "ResearchTopic",
      "StartImplementation",
      "TechnicalStrategy",
      "TriageIssues",
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
      assert {:ok, AgentTasks.FixAllBddSpecs} = SessionType.cast("FixAllBddSpecs")
      assert {:ok, AgentTasks.DevelopContext} = SessionType.cast("DevelopContext")
      assert {:ok, AgentTasks.DevelopLiveView} = SessionType.cast("DevelopLiveView")
      assert {:ok, AgentTasks.DesignUi} = SessionType.cast("DesignUi")
      assert {:ok, AgentTasks.TechnicalStrategy} = SessionType.cast("TechnicalStrategy")
      assert {:ok, AgentTasks.ResearchTopic} = SessionType.cast("ResearchTopic")
      assert {:ok, AgentTasks.DevelopLiveContext} = SessionType.cast("DevelopLiveContext")
      assert {:ok, AgentTasks.LiveContextSpec} = SessionType.cast("LiveContextSpec")
      assert {:ok, AgentTasks.QaApp} = SessionType.cast("QaApp")
      assert {:ok, AgentTasks.QaSetup} = SessionType.cast("QaSetup")
      assert {:ok, AgentTasks.QaStory} = SessionType.cast("QaStory")
      assert {:ok, AgentTasks.StartImplementation} = SessionType.cast("StartImplementation")
      assert {:ok, AgentTasks.TriageIssues} = SessionType.cast("TriageIssues")
      assert {:ok, AgentTasks.FixBddSpecs} = SessionType.cast("FixBddSpecs")
      assert {:ok, AgentTasks.FixIssues} = SessionType.cast("FixIssues")
      assert {:ok, AgentTasks.QaJourneyExecute} = SessionType.cast("QaJourneyExecute")
      assert {:ok, AgentTasks.QaJourneyPlan} = SessionType.cast("QaJourneyPlan")
      assert {:ok, AgentTasks.QaJourneyWallaby} = SessionType.cast("QaJourneyWallaby")
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
