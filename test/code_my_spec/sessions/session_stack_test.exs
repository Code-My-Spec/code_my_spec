defmodule CodeMySpec.Sessions.SessionStackTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Sessions.SessionStack
  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Sessions.Session

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "session_stack_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    {:ok, env} = CodeMySpec.Environments.create(:local, working_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{env: env, tmp_dir: tmp_dir}
  end

  describe "evaluate/2" do
    test "returns empty map when no sessions exist", %{env: env} do
      assert %{} = SessionStack.evaluate(env, [])
    end

    test "evaluates sessions in descending priority order (highest first)", %{env: env} do
      # ArchitectureReview.evaluate always returns {:ok, :valid}
      {:ok, _low} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      {:ok, _high} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 10,
          state: %{}
        })

      {:ok, _mid} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 5,
          state: %{}
        })

      # All should pass and be deleted
      result = SessionStack.evaluate(env, [])

      assert result == %{}

      # All sessions should have been deleted since they all passed
      assert {:ok, []} = SessionsRepository.list_sessions(env)
    end

    test "returns block decision with feedback from first invalid evaluation", %{env: env} do
      # ComponentSpec.evaluate tries to access session.component which won't exist
      # in our state map, causing an error that gets caught and returned as a block
      {:ok, _session} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      result = SessionStack.evaluate(env, [])

      # Should return a block decision since ComponentSpec can't evaluate properly
      assert is_map(result)
      assert result["decision"] == "block"
      assert is_binary(result["reason"])
    end

    test "deletes session when evaluation passes", %{env: env} do
      # ArchitectureReview always returns {:ok, :valid}
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      result = SessionStack.evaluate(env, [])

      assert result == %{}

      # Session should have been deleted
      assert {:error, :not_found} = SessionsRepository.get_session(env, session.id)
    end

    test "stops iteration at first invalid result (does not evaluate lower-priority sessions)",
         %{env: env} do
      # Higher priority session that will fail (ComponentSpec without proper state)
      {:ok, _failing} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      # Lower priority session that would pass
      {:ok, passing_session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      result = SessionStack.evaluate(env, [])

      # Should block on the first (highest priority) session
      assert result["decision"] == "block"

      # The lower-priority session should still exist (not evaluated/deleted)
      assert {:ok, %Session{}} = SessionsRepository.get_session(env, passing_session.id)
    end
  end
end
