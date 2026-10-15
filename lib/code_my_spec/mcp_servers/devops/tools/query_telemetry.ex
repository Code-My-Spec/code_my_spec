defmodule CodeMySpec.McpServers.Devops.Tools.QueryTelemetry do
  @moduledoc """
  Read back the calling project's own collected logs and traces.

  Scoped to the project the call resolves to -- never another project's,
  even when two projects share a telemetry host on the same server. That
  isolation is `CodeMySpec.Telemetry.query/3`'s own contract; this tool
  only adapts the MCP params into it.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Resources
  alias CodeMySpec.Telemetry

  schema do
    field :environment, :string,
      required: true,
      description: "Environment name, e.g. \"prod\" or \"uat\"."

    field :since_days, :integer,
      description:
        "How many days back to read. Defaults to the retention window " <>
          "(#{Telemetry.retention_days()} days) -- nothing older could have survived it anyway."
  end

  @impl true
  def execute(%{environment: environment} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> Telemetry.query(environment, step_opts(params))
      |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  # Same seam every provisioning step reads (`Application.get_env(:code_my_spec,
  # :provisioning_step_opts, [])`) -- a spec that stages a probe through the
  # console path should be able to stage one for this tool too, rather than
  # the only query surface being the one path that cannot be driven that way.
  defp step_opts(params) do
    :code_my_spec
    |> Application.get_env(:provisioning_step_opts, [])
    |> with_since_days(params)
  end

  defp with_since_days(opts, %{since_days: since_days}) when is_integer(since_days),
    do: Keyword.put(opts, :since_days, since_days)

  defp with_since_days(opts, _params), do: opts

  defp reply({:ok, result}, frame), do: {:reply, ok(inspect(result)), frame}
  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not query telemetry: #{inspect(reason)}")
end
