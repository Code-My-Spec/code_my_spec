defmodule CodeMySpec.Provisioning.Tools.QueryTelemetry do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Resources
  alias CodeMySpec.Telemetry

  @impl true
  def name, do: "query_telemetry"

  @impl true
  def description do
    """
    Read back the calling project's own collected logs and traces.

    Scoped to the project the call resolves to -- never another project's,
    even when two projects share a telemetry host on the same server. That
    isolation is `CodeMySpec.Telemetry.query/3`'s own contract; this tool
    only adapts the MCP params into it.
    """
  end

  @impl true
  def params do
    %{
      environment:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"prod\" or \"uat\"."]}},
      since_days:
        {:meta, :integer,
         [
           description:
             "How many days back to read. Defaults to the retention window (14 days) -- nothing older could have survived it anyway."
         ]}
    }
  end

  @impl true
  def call(%{environment: environment} = params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> Telemetry.query(environment, step_opts(params))
      |> reply()
    else
      {:error, reason} -> error(reason)
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

  defp reply({:ok, result}), do: ok(inspect(result))
  defp reply({:error, reason}), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not query telemetry: #{inspect(reason)}"}
end
