defmodule CodeMySpecSpex.Story1000.Criterion737Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 737 — An agent serves the right project with no project id configured.

  Rule: An agent learns which project it serves from its identity, not from its
  environment.

  Identity carries the project, so nothing else needs to — and nothing else is
  allowed to. The second half of this criterion is the sharp one: an operator with
  `CMS_PROJECT_ID` exported in their shell, for a different project, must not
  redirect an agent's work. That is not hypothetical. A developer working two
  projects in two terminals has exactly that variable set, and an agent that read
  it would write one project's files into the other's rows with nothing
  suspicious in any log.

  Surface: the hook endpoint. A hook arrives naming a harness and nothing else,
  which is precisely the claim — the id is sufficient, and the environment is not
  consulted.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Identity names the project" do
    scenario "An agent serves the right project with no project id configured" do
      given_ "an agent has registered against a project", context do
        # given: already true — `setup :setup_active_project` issues this scope a
        # harness, which is what registering against a project produces. Joining
        # a channel here would register a *second* agent and change what the
        # scenario is about.
        assert is_binary(context.scope.active_harness_id)

        {:ok, context}
      end

      given_ "no project id is set in its environment or its working copy", context do
        # Cleared, not assumed. This VM runs under a CodeMySpec harness, so
        # `CMS_PROJECT_ID` really is exported here — naming a different project
        # than the one under test. That is not test pollution to be tolerated,
        # it is precisely the situation the rule exists for, and leaving it set
        # would make the premise false while the scenario claimed it held.
        #
        # Restored on exit, including to "unset", so a spec that runs after this
        # one sees whatever the machine actually has.
        previous = System.get_env("CMS_PROJECT_ID")
        System.delete_env("CMS_PROJECT_ID")

        ExUnit.Callbacks.on_exit(fn ->
          if previous, do: System.put_env("CMS_PROJECT_ID", previous)
        end)

        refute System.get_env("CMS_PROJECT_ID")

        {:ok, context}
      end

      when_ "it reconnects and a hook arrives", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => "spex-no-project-id"})

        # Status captured rather than asserted here: a refusal *is* the failure
        # this criterion describes, and forcing 200 in the `when_` would kill the
        # scenario before it could say so.
        {:ok, context |> Map.put(:stop, response) |> Map.put(:stop_status, response.status)}
      end

      then_ "it acts on the project its identity names", context do
        assert context.stop_status == 200,
               "a hook naming only a harness id was refused with status " <>
                 "#{context.stop_status}, so identity alone does not resolve the project. " <>
                 "Body: #{context.stop.resp_body}"

        # A harness whose project could not be resolved answers about resolution,
        # not about the project's work. Either shape of "I do not know which
        # project this is" fails the criterion.
        rendered = context.stop.resp_body

        refute rendered =~ "no project" or rendered =~ "project_id is required",
               "the agent could not tell which project it serves from its identity alone, " <>
                 "so identity does not carry the project. Got: #{rendered}"

        {:ok, context}
      end

      then_ "a project id exported in the operator's shell does not change which project it serves",
            context do
        other_project_id = Ecto.UUID.generate()

        with_env("CMS_PROJECT_ID", other_project_id, fn ->
          response =
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{"session_id" => "spex-hijack-attempt"})

          refute response.resp_body =~ other_project_id,
                 "an exported CMS_PROJECT_ID reached the agent's work. A developer with two " <>
                   "projects in two terminals has this set, and an agent that reads it writes " <>
                   "one project's files into the other's rows with nothing suspicious in any log."
        end)

        {:ok, context}
      end
    end
  end

  # Restores whatever was there, including "nothing" — leaving a stray
  # CMS_PROJECT_ID set would silently change what every later spec in this VM
  # resolves.
  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      case previous do
        nil -> System.delete_env(name)
        old -> System.put_env(name, old)
      end
    end
  end
end
