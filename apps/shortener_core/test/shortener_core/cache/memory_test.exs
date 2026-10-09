defmodule ShortenerCore.Cache.MemoryTest do
  use ExUnit.Case, async: false
  use ShortenerCore.CacheContract, cache: ShortenerCore.Cache.Memory

  setup do
    start_supervised!(ShortenerCore.Cache.Memory)
    :ok
  end
end
