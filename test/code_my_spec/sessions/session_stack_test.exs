defmodule CodeMySpec.Sessions.SessionStackTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Sessions.SessionStack
  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Environments.Environment

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "session_stack_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    env = Environment.new(:local, tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{env: env}
  end

  describe "list_active/1" do
    test "returns {:ok, []} when no sessions exist", %{env: env} do
      assert {:ok, []} = SessionStack.list_active(env)
    end

    test "returns sessions sorted by priority descending", %{env: env} do
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

      assert {:ok, sessions} = SessionStack.list_active(env)
      assert length(sessions) == 3

      priorities = Enum.map(sessions, & &1.priority)
      assert priorities == [10, 5, 1]
    end
  end
end
