defmodule CodeMySpec.Utils.Paths do
  @moduledoc """
  Utilities for resolving and working with file system paths within the project,
  particularly for determining context paths.
  """

  alias CodeMySpec.Paths

  @doc """
  Takes any file path (spec file, implementation file, test file, or directory)
  and returns the canonical context path.

  The canonical context path is the path that can be used to query and identify
  a context in the database.

  ## Examples

      # Spec file -> context directory
      iex> resolve_context_path(".code_my_spec/spec/code_my_spec/accounts.spec.md")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts"}

      # Spec file in subdirectory -> context directory
      iex> resolve_context_path(".code_my_spec/spec/code_my_spec/accounts/accounts.spec.md")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts"}

      # Implementation context file -> context directory
      iex> resolve_context_path("lib/code_my_spec/accounts.ex")
      {:ok, "lib/code_my_spec/accounts"}

      # Component file within context -> context directory
      iex> resolve_context_path("lib/code_my_spec/accounts/user.ex")
      {:ok, "lib/code_my_spec/accounts"}

      # Direct context directory path
      iex> resolve_context_path(".code_my_spec/spec/code_my_spec/accounts")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts"}

      # Non-context file
      iex> resolve_context_path("lib/code_my_spec/utils/paths.ex")
      {:error, :not_a_context_path}
  """
  @spec resolve_context_path(String.t()) ::
          {:ok, String.t()} | {:error, :not_a_context_path}
  def resolve_context_path(path) when is_binary(path) do
    cond do
      # Spec file path
      String.ends_with?(path, ".spec.md") ->
        resolve_spec_file_path(path)

      # Implementation or test file path
      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") ->
        resolve_elixir_file_path(path)

      # Directory path
      File.dir?(path) ->
        resolve_directory_path(path)

      # Unknown path type
      true ->
        {:error, :not_a_context_path}
    end
  end

  # Resolve spec file path to context directory
  defp resolve_spec_file_path(path) do
    # Extract directory containing the spec file
    dir = Path.dirname(path)
    base_name = Path.basename(path, ".spec.md")

    # Check if the spec file name matches the directory name
    # e.g., .code_my_spec/spec/code_my_spec/accounts/accounts.spec.md -> accounts
    dir_name = Path.basename(dir)

    context_path =
      if base_name == dir_name do
        # Spec file is named after the directory (e.g., accounts/accounts.spec.md)
        dir
      else
        # Spec file is at the context level (e.g., accounts.spec.md)
        # The context directory is <dir>/<base_name>
        Path.join(dir, base_name)
      end

    {:ok, normalize_path(context_path)}
  end

  # Resolve Elixir implementation or test file to context directory
  defp resolve_elixir_file_path(path) do
    cond do
      # Test file path (test/...)
      String.starts_with?(path, "test/") ->
        resolve_test_file_path(path)

      # Implementation file path (lib/...)
      String.starts_with?(path, "lib/") ->
        resolve_lib_file_path(path)

      # Unknown Elixir file location
      true ->
        {:error, :not_a_context_path}
    end
  end

  # Resolve test file path to context directory
  defp resolve_test_file_path(path) do
    # Remove test/ prefix and _test.exs suffix
    path_without_prefix = String.replace_prefix(path, "test/", "")
    path_without_suffix = String.replace_suffix(path_without_prefix, "_test.exs", "")

    # Get directory containing the test file
    dir = Path.dirname(path_without_suffix)

    # Check if this is a context test by looking for a corresponding lib file
    context_impl_path = Path.join("lib", path_without_suffix <> ".ex")

    context_path =
      if File.exists?(context_impl_path) do
        # This is a context file test
        Path.join("lib", path_without_suffix)
      else
        # This might be a component within a context
        # The parent directory is likely the context
        Path.join("lib", dir)
      end

    {:ok, normalize_path(context_path)}
  end

  # Resolve lib file path to context directory
  defp resolve_lib_file_path(path) do
    # Remove lib/ prefix and .ex suffix
    path_without_prefix = String.replace_prefix(path, "lib/", "")
    path_without_suffix = String.replace_suffix(path_without_prefix, ".ex", "")

    # Get directory containing the file
    dir = Path.dirname(path_without_suffix)
    base_name = Path.basename(path_without_suffix)

    # Check if this is a context file (file name matches directory name)
    # e.g., lib/my_app/accounts.ex (context) vs lib/my_app/accounts/user.ex (component)
    parent_dir = Path.basename(dir)

    context_path =
      if base_name == parent_dir or dir == "." do
        # This is a context file (lib/my_app/accounts.ex)
        # Context path is lib/<path_without_suffix>
        Path.join("lib", path_without_suffix)
      else
        # This is a component file within a context
        # Context path is lib/<dir>
        Path.join("lib", dir)
      end

    {:ok, normalize_path(context_path)}
  end

  # Resolve directory path
  defp resolve_directory_path(path) do
    normalized_path = normalize_path(path)

    # Check if this directory represents a valid context
    # A valid context directory should have either:
    # 1. A matching spec file (e.g., .code_my_spec/spec/.../accounts with accounts.spec.md inside)
    # 2. A matching implementation file (e.g., lib/.../accounts with accounts.ex inside)

    base_name = Path.basename(normalized_path)

    is_valid_context =
      cond do
        # Check for spec file in the directory
        String.starts_with?(normalized_path, Paths.spec_prefix()) ->
          spec_file = Path.join(normalized_path, "#{base_name}.spec.md")
          File.exists?(spec_file)

        # Check for implementation file
        String.starts_with?(normalized_path, "lib/") ->
          # Extract path after lib/
          path_after_lib = String.replace_prefix(normalized_path, "lib/", "")
          impl_file = Path.join("lib", "#{path_after_lib}.ex")
          File.exists?(impl_file) or File.dir?(normalized_path)

        # Unknown directory location
        true ->
          false
      end

    if is_valid_context do
      {:ok, normalized_path}
    else
      {:error, :not_a_context_path}
    end
  end

  # Normalize path by removing trailing slashes and resolving relative paths
  defp normalize_path(path) do
    path
    |> String.trim_trailing("/")
    |> Path.expand()
    |> Path.relative_to(File.cwd!())
  end

  @doc """
  Converts a module name to a file system path.

  ## Examples

      iex> module_to_path("MyApp.Accounts.User")
      "my_app/accounts/user"

      iex> module_to_path("MyApp.Accounts")
      "my_app/accounts"
  """
  @spec module_to_path(String.t()) :: String.t()
  def module_to_path(module_name) when is_binary(module_name) do
    module_name
    |> String.replace_prefix("", "")
    |> Macro.underscore()
    |> String.replace(".", "/")
    |> String.downcase()
  end

  @doc """
  Takes any file path (spec, implementation, test, or directory) and returns
  the corresponding spec file path.

  ## Examples

      # From implementation file
      iex> spec_path("lib/code_my_spec/accounts.ex")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts.spec.md"}

      # From component file
      iex> spec_path("lib/code_my_spec/accounts/user.ex")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts.spec.md"}

      # From test file
      iex> spec_path("test/code_my_spec/accounts_test.exs")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts.spec.md"}

      # From spec file (returns same)
      iex> spec_path(".code_my_spec/spec/code_my_spec/accounts.spec.md")
      {:ok, ".code_my_spec/spec/code_my_spec/accounts.spec.md"}
  """
  @spec spec_path(String.t()) :: {:ok, String.t()} | {:error, :not_a_context_path}
  def spec_path(path) when is_binary(path) do
    with {:ok, context_path} <- resolve_context_path(path) do
      # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
      # Extract the context name from the context path
      # e.g., "lib/code_my_spec/accounts" -> "accounts"
      context_name = Path.basename(context_path)

      # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
      # Build the spec directory path
      # e.g., "lib/code_my_spec/accounts" -> ".code_my_spec/spec/code_my_spec"
      spec_base_dir =
        context_path
        |> String.replace_prefix("lib/", Paths.spec_prefix())
        |> String.replace_prefix("test/", Paths.spec_prefix())
        |> Path.dirname()

      spec_file_path = Path.join(spec_base_dir, "#{context_name}.spec.md")
      {:ok, spec_file_path}
    end
  end

  @doc """
  Takes any file path (spec, implementation, test, or directory) and returns
  the corresponding implementation directory path.

  ## Examples

      # From spec file
      iex> implementation_path(".code_my_spec/spec/code_my_spec/accounts.spec.md")
      {:ok, "lib/code_my_spec/accounts"}

      # From implementation file
      iex> implementation_path("lib/code_my_spec/accounts.ex")
      {:ok, "lib/code_my_spec/accounts"}

      # From component file
      iex> implementation_path("lib/code_my_spec/accounts/user.ex")
      {:ok, "lib/code_my_spec/accounts"}
  """
  @spec implementation_path(String.t()) :: {:ok, String.t()} | {:error, :not_a_context_path}
  def implementation_path(path) when is_binary(path) do
    with {:ok, context_path} <- resolve_context_path(path) do
      # If already in lib, return as-is
      if String.starts_with?(context_path, "lib/") do
        {:ok, context_path}
      else
        # Convert from spec path to lib path
        # e.g., ".code_my_spec/spec/code_my_spec/accounts" -> "lib/code_my_spec/accounts"
        lib_path = String.replace_prefix(context_path, Paths.spec_prefix(), "lib/")
        {:ok, lib_path}
      end
    end
  end

  @doc """
  Takes any file path (spec, implementation, test, or directory) and returns
  the corresponding test directory path.

  ## Examples

      # From spec file
      iex> test_path(".code_my_spec/spec/code_my_spec/accounts.spec.md")
      {:ok, "test/code_my_spec"}

      # From implementation file
      iex> test_path("lib/code_my_spec/accounts.ex")
      {:ok, "test/code_my_spec"}
  """
  @spec test_path(String.t()) :: {:ok, String.t()} | {:error, :not_a_context_path}
  def test_path(path) when is_binary(path) do
    with {:ok, context_path} <- resolve_context_path(path) do
      # Convert to test path
      test_base_path =
        context_path
        |> String.replace_prefix("lib/", "test/")
        |> String.replace_prefix(Paths.spec_prefix(), "test/")

      {:ok, test_base_path}
    end
  end
end
