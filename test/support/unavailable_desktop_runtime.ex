defmodule CodeMySpecTest.UnavailableDesktopRuntime do
  @moduledoc false

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(_opts), do: {:error, :database_unavailable}
end
