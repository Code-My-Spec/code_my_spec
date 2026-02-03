defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Sessions` context.
  """

  alias CodeMySpec.Sessions.{Command, Interaction, InteractionsRepository}

  @doc """
  Generate a session.
  """
  def session_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        agent: :claude_code,
        environment_type: :local,
        state: %{},
        status: :active,
        type: CodeMySpec.Sessions.AgentTasks.ContextSpec,
        display_name: "Context Spec",
        interactions: []
      })

    {:ok, session} = CodeMySpec.Sessions.create_session(scope, attrs)

    # Reload with same preloads as list_sessions/1
    CodeMySpec.Repo.preload(session, [:project, :component, :interactions])
  end

  @doc """
  Generate an interaction for a session.
  """
  def interaction_fixture(session, attrs \\ %{}) do
    # Create a test command - use a valid step module from the session type
    module = Map.get(attrs, :module, get_default_step_module(session.type))

    command =
      Command.new(
        module,
        Map.get(attrs, :command, "claude"),
        metadata: Map.get(attrs, :metadata, %{prompt: "Test prompt"})
      )

    # Create interaction with command
    interaction = Interaction.new_with_command(command)

    # Insert into database
    {:ok, created_interaction} = InteractionsRepository.create(session.id, interaction)

    created_interaction
  end

  defp get_default_step_module(CodeMySpec.ComponentCodingSessions),
    do: CodeMySpec.ComponentCodingSessions.Steps.Initialize

  defp get_default_step_module(_), do: nil

  @doc """
  Generate valid event attributes for testing.
  """
  def valid_event_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "event_type" => :proxy_response,
      "sent_at" => DateTime.utc_now(),
      "data" => %{
        "tool_name" => "Read",
        "file_path" => "/path/to/file.ex"
      }
    })
  end

  @doc """
  Generate a conversation_started event.
  """
  def conversation_started_event_attrs(conversation_id, attrs \\ %{}) do
    Enum.into(attrs, %{
      "event_type" => :session_start,
      "sent_at" => DateTime.utc_now(),
      "data" => %{
        "session_id" => conversation_id,
        "agent" => "claude_code",
        "model" => "claude-sonnet-4"
      }
    })
  end
end
