defmodule CodeMySpec.AgentAttachments do
  @moduledoc "Main's working-copy attachments, separate from where its agent runs."
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.Agent,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  import Ecto.Query
  alias CodeMySpec.AgentAttachments.Attachment
  alias CodeMySpec.AgentAttachments.Transport
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @timeout 15_000
  # The agents' own tools (`CmsHarness.Agents.CoreTools`), run in the attached
  # copy: same tools, separate transport (issue 2394520b).
  @tools ~w(read write edit bash)
  # Bash owns a deadline of up to an hour, as an agent's does; the request
  # outlives it so the tool, not the wire, reports a timeout.
  @tool_timeout :timer.hours(1) + 15_000

  def list(scope, agent_id) do
    with {:ok, agent} <- caller(scope, agent_id) do
      Repo.all(from a in Attachment, where: a.agent_id == ^agent.id, order_by: a.inserted_at)
    end
  end

  def connect(scope, agent_id, copy_id) do
    with {:ok, agent} <- caller(scope, agent_id),
         {:ok, copy} <- target(scope, copy_id) do
      Repo.transaction(fn -> connect_locked(agent, copy.id) end)
    end
  end

  defp connect_locked(agent, copy_id) do
    Repo.lock!("agent-attachment:#{agent.id}:#{copy_id}")
    existing = Repo.get_by(Attachment, agent_id: agent.id, working_copy_id: copy_id)
    attachment = existing || new_attachment(agent, copy_id)

    case request(copy_id, "attachment_connect", %{"attachment_id" => attachment.id}) do
      {:ok, _handle} -> persist(existing, attachment)
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback({:unexpected_attachment_reply, other})
    end
  end

  def disconnect(scope, agent_id, attachment_id) do
    with {:ok, attachment} <- authorized(scope, agent_id, attachment_id),
         {:ok, _} <- revoke(attachment) do
      request(attachment.working_copy_id, "attachment_disconnect", %{
        "attachment_id" => attachment.id
      })
    end
  end

  defp revoke(attachment) do
    Repo.transaction(fn ->
      Repo.lock!("agent-attachment:#{attachment.agent_id}:#{attachment.working_copy_id}")

      case Repo.get(Attachment, attachment.id) do
        nil -> Repo.rollback(:attachment_not_found)
        current -> Repo.delete!(current)
      end
    end)
  end

  @doc "Run one of the agents' own tools (`tool`, with that tool's own `input`) in the attached copy."
  def execute(scope, agent_id, attachment_id, tool, input) when is_map(input) do
    with {:ok, attachment} <- authorized(scope, agent_id, attachment_id),
         :ok <- valid_tool(tool),
         {:ok, _copy} <- target(scope, attachment.working_copy_id) do
      payload = %{
        "attachment_id" => attachment.id,
        "working_copy_id" => attachment.working_copy_id,
        "tool" => tool,
        "input" => Map.new(input, fn {key, value} -> {to_string(key), value} end)
      }

      request(attachment.working_copy_id, "attachment_execute", payload, @tool_timeout)
    end
  end

  def execute(_, _, _, _, _), do: {:error, :invalid_payload}

  defp valid_tool(tool) when tool in @tools, do: :ok
  defp valid_tool(_), do: {:error, :unsupported_tool}

  defp caller(%Scope{active_project_id: project, active_account_id: account}, id)
       when is_binary(project) and is_binary(account) do
    with {:ok, uuid} <- uuid(id),
         %Agent{role: :main, retired_at: nil, off_at: nil} = agent <-
           Repo.get_by(Agent, id: uuid, project_id: project, account_id: account) do
      {:ok, agent}
    else
      _ -> {:error, :unauthorized_agent}
    end
  end

  defp caller(_, _), do: {:error, :unauthorized_agent}

  defp target(%Scope{active_project_id: project}, id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{project_id: ^project, root: root} = copy} when is_binary(root) and root != "" ->
        {:ok, copy}

      _ ->
        {:error, :working_copy_not_found}
    end
  end

  defp authorized(scope, agent_id, attachment_id) do
    with {:ok, agent} <- caller(scope, agent_id),
         {:ok, id} <- uuid(attachment_id),
         %Attachment{} = attachment <-
           Repo.get_by(Attachment, id: id, agent_id: agent.id, project_id: agent.project_id) do
      {:ok, attachment}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attachment_not_found}
    end
  end

  defp new_attachment(agent, copy_id) do
    %Attachment{
      id: Ecto.UUID.generate(),
      agent_id: agent.id,
      working_copy_id: copy_id,
      project_id: agent.project_id,
      account_id: agent.account_id
    }
  end

  defp persist(nil, attachment) do
    case attachment |> Attachment.changeset(%{}) |> Repo.insert() do
      {:ok, saved} ->
        saved

      {:error, error} ->
        request(attachment.working_copy_id, "attachment_disconnect", %{
          "attachment_id" => attachment.id
        })

        Repo.rollback(error)
    end
  end

  defp persist(existing, _attachment), do: existing

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp request(copy_id, operation, payload, timeout \\ @timeout) do
    Application.get_env(:code_my_spec, :agent_attachment_transport, Transport).request(
      copy_id,
      operation,
      payload,
      timeout
    )
  end
end
