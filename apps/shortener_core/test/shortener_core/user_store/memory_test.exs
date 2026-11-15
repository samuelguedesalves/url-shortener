defmodule ShortenerCore.UserStore.MemoryTest do
  use ExUnit.Case, async: false
  use ShortenerCore.UserStoreContract, store: ShortenerCore.UserStore.Memory

  setup do
    start_supervised!(ShortenerCore.UserStore.Memory)
    :ok
  end
end
