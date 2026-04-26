defmodule CodeMySpec.ElixirAstFixtures do
  @moduledoc false
  def sample_module_with_single_alias do
    """
    defmodule MyApp.Example do
      alias MyApp.User

      def get_user(id) do
        User.find(id)
      end
    end
    """
  end

  def sample_module_with_multi_alias do
    """
    defmodule MyApp.Example do
      alias MyApp.{User, Post, Comment}

      def process do
        :ok
      end
    end
    """
  end

  def sample_module_with_import do
    """
    defmodule MyApp.Example do
      import Ecto.Query

      def list_users do
        from(u in User, select: u)
      end
    end
    """
  end

  def sample_module_with_use do
    """
    defmodule MyApp.Example do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end
    end
    """
  end

  def sample_module_with_all_dependencies do
    """
    defmodule MyApp.Example do
      alias MyApp.User
      alias MyApp.{Post, Comment}
      import Ecto.Query
      use GenServer

      def process do
        :ok
      end
    end
    """
  end

  def sample_module_with_duplicate_dependencies do
    """
    defmodule MyApp.Example do
      alias MyApp.User
      import MyApp.User
      use MyApp.User

      def process do
        :ok
      end
    end
    """
  end

  def sample_module_with_alias_as do
    """
    defmodule MyApp.Example do
      alias MyApp.Accounts.User, as: AccountUser
      alias MyApp.Blog.User, as: BlogUser

      def get_users do
        {AccountUser.all(), BlogUser.all()}
      end
    end
    """
  end

  def sample_module_with_invalid_syntax do
    """
    defmodule MyApp.Example do
      alias MyApp.User

      def broken(
    end
    """
  end

  def sample_module_no_dependencies do
    """
    defmodule MyApp.Example do
      def simple_function(x) do
        x + 1
      end
    end
    """
  end

  def sample_module_with_public_functions do
    """
    defmodule MyApp.Example do
      @spec get_user(integer()) :: {:ok, map()} | {:error, term()}
      def get_user(id) do
        {:ok, %{id: id}}
      end

      @spec list_users() :: [map()]
      def list_users do
        []
      end
    end
    """
  end

  def sample_module_with_private_functions do
    """
    defmodule MyApp.Example do
      def public_function(x) do
        private_function(x)
      end

      defp private_function(x) do
        x * 2
      end

      defp another_private(x) do
        x + 1
      end
    end
    """
  end

  def sample_module_without_specs do
    """
    defmodule MyApp.Example do
      def function_without_spec(x) do
        x + 1
      end

      def another_function(x, y) do
        x + y
      end
    end
    """
  end

  def sample_module_with_multi_clause_functions do
    """
    defmodule MyApp.Example do
      def process(:start) do
        :started
      end

      def process(:stop) do
        :stopped
      end

      def process(_) do
        :unknown
      end
    end
    """
  end

  def sample_module_with_default_arguments do
    """
    defmodule MyApp.Example do
      @spec greet(String.t(), String.t()) :: String.t()
      def greet(name, greeting \\\\ "Hello") do
        "\#{greeting}, \#{name}!"
      end
    end
    """
  end

  def sample_module_with_guards do
    """
    defmodule MyApp.Example do
      def process(x) when is_integer(x) and x > 0 do
        x * 2
      end

      def process(_) do
        :error
      end
    end
    """
  end

  def sample_module_with_pattern_matching do
    """
    defmodule MyApp.Example do
      def handle({:ok, value}) do
        value
      end

      def handle({:error, _reason}) do
        nil
      end
    end
    """
  end

  def sample_module_no_public_functions do
    """
    defmodule MyApp.Example do
      defp private_only(x) do
        x + 1
      end

      defp another_private(y) do
        y * 2
      end
    end
    """
  end

  def sample_script_no_module do
    """
    # This is a script file, not a module

    IO.puts("Hello, world!")

    result = 1 + 2
    IO.inspect(result)
    """
  end

  def sample_test_file_simple do
    """
    defmodule MyApp.ExampleTest do
      use ExUnit.Case, async: true

      test "adds two numbers" do
        assert 1 + 1 == 2
      end

      test "subtracts two numbers" do
        assert 2 - 1 == 1
      end
    end
    """
  end

  def sample_test_file_with_describe do
    """
    defmodule MyApp.ExampleTest do
      use ExUnit.Case, async: true

      describe "addition" do
        test "adds positive numbers" do
          assert 1 + 1 == 2
        end

        test "adds negative numbers" do
          assert -1 + -1 == -2
        end
      end

      describe "subtraction" do
        test "subtracts positive numbers" do
          assert 2 - 1 == 1
        end
      end
    end
    """
  end

  def sample_test_file_nested_describe do
    """
    defmodule MyApp.ExampleTest do
      use ExUnit.Case, async: true

      describe "outer context" do
        describe "inner context" do
          test "nested test" do
            assert true
          end
        end
      end
    end
    """
  end

  def sample_test_file_with_doctest do
    """
    defmodule MyApp.ExampleTest do
      use ExUnit.Case, async: true

      doctest MyApp.Example

      test "simple test" do
        assert true
      end
    end
    """
  end

  def sample_non_test_file do
    """
    defmodule MyApp.Example do
      def regular_function do
        :ok
      end
    end
    """
  end

  def sample_test_file_no_tests do
    """
    defmodule MyApp.ExampleTest do
      use ExUnit.Case, async: true

      # No tests defined yet
    end
    """
  end
end
