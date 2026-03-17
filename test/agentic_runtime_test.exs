defmodule AgenticRuntimeTest do
  use ExUnit.Case
  doctest AgenticRuntime

  test "greets the world" do
    assert AgenticRuntime.hello() == :world
  end
end
