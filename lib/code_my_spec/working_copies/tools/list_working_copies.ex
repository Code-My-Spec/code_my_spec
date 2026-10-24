defmodule CodeMySpec.WorkingCopies.Tools.ListWorkingCopies do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.AppInstances
  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "list_working_copies"

  @impl true
  def description do
    """
    The checkouts this project has, and what is running on each.

    So that deciding where an epic goes can be a decision. John: *"if there's an
    appropriate working copy and agent then it should get assigned that, or maybe
    the agent wants a fresh working copy ... the user should be able to decide
    where to assign it or the agent should be able to decide."*

    Neither could, before this: there was no agent-facing way to see a project's
    checkouts at all, so "an appropriate one" was not a judgement anything could
    make.

    ## What to look at

    `root` is the only thing that makes a row a checkout — a row with none has no
    disk behind it and nothing can be built there. `agents` is what is already
    running, which is the difference between assigning to a copy that can pick the
    work up and assigning to an idle one that needs an agent started first.

    `main` is the project's own checkout, the one story 963's agent runs in. It is
    a fine destination and not automatically the right one; a copy already holding
    a related epic often is.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        {:ok, render(scope)}

      {:error, atom} ->
        {:error, inspect(atom)}
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      running = running_by_copy(scope)

      {:ok,
       Enum.map(WorkingCopies.list_harnesses(scope), &row(scope, &1, Map.get(running, &1.id, [])))}
    end
  end

  # String keys and plain values: these cross into a Lua VM, where an atom
  # key and a struct are not things that exist.
  defp row(scope, copy, agents) do
    device = copy.device_id && Devices.get_device(scope, copy.device_id)
    instances = AppInstances.list_for_working_copy(scope, copy)
    instance = Enum.find(instances, & &1.default)

    %{
      "id" => copy.id,
      "root" => copy.root,
      "device_id" => copy.device_id,
      "device_name" => device && device.hostname,
      "main" => copy.main,
      "promotion_sync" => instance && instance.promotion_sync,
      "app_instance" => if(instance, do: AppInstances.descriptor(instance)),
      "app_status" => instance && instance.status,
      "app_serving_commit" => instance && instance.serving_commit,
      "app_instances" => Enum.map(instances, &instance_row/1),
      "agents" => Enum.map(agents, &agent_row/1)
    }
  end

  defp instance_row(instance) do
    AppInstances.descriptor(instance)
    |> Map.merge(%{
      "environment_id" => instance.environment_id,
      "status" => instance.status,
      "url" => instance.url,
      "commit" => instance.commit,
      "serving_commit" => instance.serving_commit,
      "checked_at" => if(instance.checked_at, do: DateTime.to_iso8601(instance.checked_at)),
      "preview_status" => instance.preview_status,
      "preview_url" => instance.preview_url
    })
  end

  defp agent_row({agent, lifecycle}) do
    %{"role" => to_string(agent.role), "status" => to_string(lifecycle)}
  end

  defp render(scope) do
    case WorkingCopies.list_harnesses(scope) do
      [] ->
        "This project has no checkouts. Nothing can be built until one reports in."

      copies ->
        running = running_by_copy(scope)

        Enum.map_join(copies, "\n", &line(scope, &1, Map.get(running, &1.id, [])))
    end
  end

  defp line(scope, copy, agents) do
    instances = AppInstances.list_for_working_copy(scope, copy)
    instance = Enum.find(instances, & &1.default)

    [
      copy.id,
      describe_root(copy.root),
      if(copy.main, do: "main", else: "—"),
      describe_agents(agents),
      describe_sync(instance && instance.promotion_sync),
      describe_app(instances)
    ]
    |> Enum.join("  |  ")
  end

  # Said in words rather than left blank, because a row with no root is the one
  # a reader is most likely to pick by mistake — it looks like a checkout in a
  # list of checkouts. Issue 28e838cc is that mistake made by code.
  defp describe_root(root) when is_binary(root) and root != "", do: root
  defp describe_root(_), do: "no checkout on disk — nothing can be built here"

  defp describe_sync(%{"status" => status, "head" => head} = sync),
    do:
      "device sync #{status} at #{head}" <> if(sync["error"], do: ": #{sync["error"]}", else: "")

  defp describe_sync(_), do: "no pending publication"

  defp describe_app([]), do: "no app instance"

  defp describe_app(instances) do
    Enum.map_join(instances, "; ", fn instance ->
      "app #{instance.id} #{instance.status || "not reported"}"
    end)
  end

  defp describe_agents([]), do: "nothing running"

  defp describe_agents(agents) do
    Enum.map_join(agents, ", ", fn {agent, lifecycle} -> "#{agent.role} (#{lifecycle})" end)
  end

  # Every agent on duty, with its derived state: one still starting is shown as
  # starting rather than left off the list.
  defp running_by_copy(scope) do
    present = Agents.present_ids(scope)

    scope
    |> Agents.list_on_duty()
    |> Enum.map(&{&1, Agents.lifecycle(&1, present)})
    |> Enum.group_by(fn {agent, _} -> agent.working_copy_id end)
  end
end
