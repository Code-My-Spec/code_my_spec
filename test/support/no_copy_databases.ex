defmodule CmsHarnessTest.NoCopyDatabases do
  @moduledoc "The suite's `CmsHarness.CopyDatabases` runner: finds no database, drops none."
  def idle_databases_matching(_regex), do: []
  def drop_database(_database), do: :ok
end
