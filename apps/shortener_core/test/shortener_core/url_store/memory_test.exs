defmodule ShortenerCore.UrlStore.MemoryTest do
  use ExUnit.Case, async: false
  use ShortenerCore.UrlStoreContract, store: ShortenerCore.UrlStore.Memory

  setup do
    start_supervised!(ShortenerCore.UrlStore.Memory)
    :ok
  end
end
