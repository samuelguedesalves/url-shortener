defmodule ShortenerCore.CacheContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.Cache` implementations.

      use ShortenerCore.CacheContract, cache: MyCache
  """

  defmacro __using__(opts) do
    cache = Keyword.fetch!(opts, :cache)

    quote do
      @cache unquote(cache)

      defp code, do: "c" <> ShortenerCore.Base62.random(8)

      test "get on an unknown code is a miss" do
        assert @cache.get(code()) == :miss
      end

      test "stores and returns a destination" do
        code = code()
        assert @cache.put(code, {:url, "https://example.com/x?y=1"}, 60) == :ok
        assert @cache.get(code) == {:ok, {:url, "https://example.com/x?y=1"}}
      end

      test "stores and returns negative entries" do
        a = code()
        b = code()
        assert @cache.put(a, :not_found, 60) == :ok
        assert @cache.put(b, :gone, 60) == :ok
        assert @cache.get(a) == {:ok, :not_found}
        assert @cache.get(b) == {:ok, :gone}
      end

      test "delete removes an entry and is safe on a missing one" do
        code = code()
        assert @cache.put(code, :not_found, 60) == :ok
        assert @cache.delete(code) == :ok
        assert @cache.get(code) == :miss
        assert @cache.delete(code) == :ok
      end

      test "a destination that looks like a negative marker is returned as a destination" do
        code = code()
        assert @cache.put(code, {:url, "N"}, 60) == :ok
        assert @cache.get(code) == {:ok, {:url, "N"}}
      end
    end
  end
end
