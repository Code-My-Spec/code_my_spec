defmodule CodeMySpec.CopyTools.Transport do
  @moduledoc "The request seam to the harness holding a working copy."
  alias CodeMySpec.Analysis.HarnessRegistry

  @callback request(String.t(), String.t(), map(), timeout()) ::
              :ok | {:ok, term()} | {:error, term()}

  def request(copy_id, operation, payload, timeout) do
    case HarnessRegistry.executor_holder(copy_id) do
      {:ok, _, _} ->
        if HarnessRegistry.supports?(copy_id, "copy_tools") do
          transport = Application.fetch_env!(:code_my_spec, :harness_fs_transport)
          transport.harness_fs_request(copy_id, operation, payload, timeout)
        else
          {:error, :copy_tools_unsupported}
        end

      :error ->
        {:error, :harness_unreachable}
    end
  end
end
