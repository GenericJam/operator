defmodule Mix.Tasks.Operator.LoginTest do
  # async: false: Mix.shell/1 is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Operator.Login

  @path "/callback"
  @state "the-state"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  # What the listener sends for one browser request; the page's answer
  # comes back to this process as `{ref, status, text}`.
  defp redirect(params, path \\ @path) do
    ref = make_ref()
    send(self(), {:redirect, self(), ref, path, params})
    ref
  end

  defp await, do: Login.await_code(@path, @state, System.monotonic_time(:millisecond) + 1_000)

  test "the redirect carrying this sign-in's state gives the code" do
    ref = redirect(%{"code" => "abc", "state" => @state})

    assert await() == "abc"
    assert_received {^ref, 200, _}
  end

  test "an error or code carrying another state is turned away and the wait goes on" do
    denied = redirect(%{"error" => "access_denied", "state" => "an-older-state"})
    no_state = redirect(%{"error" => "access_denied"})
    stale = redirect(%{"code" => "old", "state" => "an-older-state"})
    favicon = redirect(%{}, "/favicon.ico")
    good = redirect(%{"code" => "abc", "state" => @state})

    assert await() == "abc"
    assert_received {^denied, 400, _}
    assert_received {^no_state, 400, _}
    assert_received {^stale, 400, _}
    assert_received {^favicon, 404, _}
    assert_received {^good, 200, _}
  end

  test "an error carrying this sign-in's state ends it" do
    ref = redirect(%{"error" => "access_denied", "state" => @state})

    assert_raise Mix.Error, ~r/access_denied/, fn -> await() end
    assert_received {^ref, 400, _}
  end

  test "a pasted code#state, redirect URL or bare code finishes the sign-in" do
    send(self(), {:stdin, "abc##{@state}\n"})
    assert await() == "abc"

    send(self(), {:stdin, "http://localhost:54545/callback?code=def&state=#{@state}\n"})
    assert await() == "def"

    send(self(), {:stdin, "  ghi \n"})
    assert await() == "ghi"
  end

  test "a pasted code for another sign-in, or no code, is refused and the wait goes on" do
    send(self(), {:stdin, "\n"})
    send(self(), {:stdin, "old#an-older-state\n"})
    send(self(), {:stdin, "#only-a-state\n"})
    send(self(), {:stdin, "abc##{@state}\n"})

    assert await() == "abc"
    assert_received {:mix_shell, :info, ["That code belongs to another sign-in" <> _]}
    assert_received {:mix_shell, :info, ["No code in that" <> _]}
    refute_received {:mix_shell, :info, _}
  end

  test "no answer before the deadline ends the wait" do
    assert_raise Mix.Error, ~r/No sign-in/, fn ->
      Login.await_code(@path, @state, System.monotonic_time(:millisecond))
    end
  end
end
