defmodule ShortenerCore.KeySource.InProcessTest do
  use ExUnit.Case, async: true
  use ShortenerCore.KeySourceContract, source: ShortenerCore.KeySource.InProcess
end
