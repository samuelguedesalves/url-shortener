defmodule ShortenerCore.Cache.RedisTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  use ShortenerCore.CacheContract, cache: ShortenerCore.Cache.Redis

  setup do
    start_supervised!(ShortenerCore.Redis)
    :ok
  end

  test "put sets the TTL on the key" do
    code = code()
    assert @cache.put(code, {:url, "https://example.com"}, 120) == :ok
    assert {:ok, ttl} = Redix.command(ShortenerCore.Redis.conn(), ["TTL", "url:" <> code])
    assert ttl in 119..120
  end

  test "returns {:error, :unavailable} when Redis cannot be reached" do
    stop_supervised!(ShortenerCore.Redis)
    start_supervised!({ShortenerCore.Redis, url: "redis://127.0.0.1:1"}, id: :unreachable)

    assert @cache.get(code()) == {:error, :unavailable}
    assert @cache.put(code(), :not_found, 60) == {:error, :unavailable}
    assert @cache.delete(code()) == {:error, :unavailable}
  end
end
