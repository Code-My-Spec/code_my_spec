defmodule CodeMySpec.Agents.Agent.TaskTypeTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Agent.Task
  alias CodeMySpec.Agents.Agent.TaskType
  alias CodeMySpec.AgentTasks

  describe "cast/1" do
    test "resolves a short name against the agent task namespace" do
      assert {:ok, AgentTasks.ComponentCode} = TaskType.cast("ComponentCode")
      assert {:ok, AgentTasks.QaStory} = TaskType.cast("QaStory")
      assert {:ok, AgentTasks.StartImplementation} = TaskType.cast("StartImplementation")
    end

    test "accepts a full atom string and the atom itself" do
      assert {:ok, AgentTasks.WriteBddSpecs} =
               TaskType.cast("Elixir.CodeMySpec.AgentTasks.WriteBddSpecs")

      assert {:ok, AgentTasks.WriteBddSpecs} = TaskType.cast(AgentTasks.WriteBddSpecs)
    end

    test "accepts nil: a task with no module" do
      assert {:ok, nil} = TaskType.cast(nil)
    end

    test "rejects what is not a loaded agent task module" do
      for invalid <- ["InvalidType", "", 123, %{}, [], :invalid_atom, SomeOtherModule] do
        assert :error = TaskType.cast(invalid)
      end
    end
  end

  describe "load/1 — tolerance for legacy rows" do
    # A row naming a module that no longer exists must still load: `load/1` is
    # tolerant while `cast/1` stays strict, so new writes are still rejected
    # but an old row cannot take down every query that materialises an agent
    # (issue f79da343).
    test "loads a type whose module no longer exists" do
      assert {:ok, _} = TaskType.load("Elixir.CodeMySpec.ComponentDesignSessions")
    end

    test "loads a type that was never a module at all" do
      assert {:ok, _} = TaskType.load("Elixir.CodeMySpec.AgentTasks.NeverExisted")
    end

    test "cast/1 stays strict — a deleted module is still rejected on write" do
      assert :error = TaskType.cast("Elixir.CodeMySpec.ComponentDesignSessions")
    end
  end

  describe "persisted JSON task history" do
    test "a removed task type loads from an agent's embeds" do
      stored_task = %{
        "id" => "historical-task",
        "status" => "completed",
        "session_type" => "Elixir.CodeMySpec.AgentTasks.FixStoryIssues",
        "story_id" => 601,
        "requirement_name" => "story_issues_resolved"
      }

      agent = Ecto.embedded_load(Agent, %{"tasks" => [stored_task]}, :json)
      assert [task] = agent.tasks
      assert task.id == "historical-task"
      assert task.status == :completed
      assert task.story_id == 601
      assert task.session_type == CodeMySpec.AgentTasks.FixStoryIssues
      assert Ecto.embedded_dump(task, :json)[:session_type] == stored_task["session_type"]
    end

    test "a removed task type remains invalid for newly created tasks" do
      changeset =
        Task.changeset(%{
          id: "new-task",
          status: :active,
          session_type: "Elixir.CodeMySpec.AgentTasks.FixStoryIssues"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :session_type)
    end

    test "current submission tasks round-trip through their persisted JSON representation" do
      task = %Task{
        id: "submission-task",
        status: :active,
        session_type: AgentTasks.SubmitStoryIssue
      }

      stored = task |> Ecto.embedded_dump(:json) |> Jason.encode!() |> Jason.decode!()

      assert stored["session_type"] == "Elixir.CodeMySpec.AgentTasks.SubmitStoryIssue"
      assert Ecto.embedded_load(Task, stored, :json) == task
    end
  end
end
