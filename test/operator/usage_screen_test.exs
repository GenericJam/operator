defmodule Operator.UsageScreenTest do
  use Mob.ScreenCase, async: true

  alias Operator.Core.Budget
  alias Operator.Core.Session
  alias Operator.Core.Usage
  alias Operator.UsageScreen

  @moduletag :tmp_dir

  @claude "anthropic:claude-sonnet-4-5"

  defp mount_usage(dir, params) do
    params =
      Map.merge(
        %{data_dir: dir, signed_in: [], refresh: fn _dir, _p -> :ok end, model: @claude},
        params
      )

    mount_screen(UsageScreen, params)
  end

  test "nothing recorded yet: every section says so", %{tmp_dir: dir} do
    view = mount_usage(dir, %{signed_in: [:anthropic]})
    assert_renderable(view)
    shown = text(view)

    assert shown =~ "menu › usage"
    assert shown =~ "Claude (Anthropic)"
    assert shown =~ "no numbers yet: make a model call, or refresh"
    assert shown =~ "ChatGPT (OpenAI Codex)"
    assert shown =~ "not signed in"
    assert shown =~ "no session file yet"
    assert shown =~ "today     0 req · $0.0000"
    assert shown =~ "no model calls recorded yet"
  end

  test "the windows, the last 429, the session, today and per model", %{tmp_dir: dir} do
    now = System.os_time(:second)

    headers = [
      {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
      {"anthropic-ratelimit-unified-5h-reset", "#{now + 7500}"},
      {"anthropic-ratelimit-unified-7d-utilization", "0.18"},
      {"anthropic-ratelimit-unified-7d-reset", "#{now + 3 * 86_400 + 4000}"}
    ]

    usage = %{input_tokens: 2500, output_tokens: 400, total_cost: 0.0123}
    :ok = Usage.record(dir, @claude, %{status: 200, headers: headers, usage: usage}, now)

    :ok =
      Usage.record(
        dir,
        "openai_codex:gpt-5",
        %{
          status: 429,
          headers: [{"x-codex-primary-used-percent", "100"}, {"retry-after", "600"}],
          error: "usage_limit_reached"
        },
        now
      )

    session = Session.new(dir, @claude, dir)

    {session, _} =
      Session.append(
        session,
        Session.assistant(%{text: "hi", usage: usage, stop_reason: "stop"}, @claude)
      )

    view = mount_usage(dir, %{path: session.path})
    shown = text(view)

    assert shown =~ "5 hours  [####......] 42%"
    assert shown =~ "resets in 2h 5m"
    assert shown =~ "7 days   [##........] 18%"
    assert shown =~ "resets in 3d 1h"
    assert shown =~ "from the last call's headers"
    assert shown =~ "last 429 <1m ago (gpt-5): resets in 10m"
    assert shown =~ "usage_limit_reached"
    assert shown =~ "session   1 req · $0.0123"
    assert shown =~ "today     2 req · 1 failed · $0.0123"
    assert shown =~ "in 2.5k · out 400"
    assert shown =~ "claude-sonnet-4-5 1 req · $0.0123"
    assert shown =~ "gpt-5 1 req · 1 failed"
    assert Usage.by_model(Usage.load(dir), Budget.today()) != %{}
  end

  test "opening asks the signed-in providers' endpoints; refresh asks again", %{tmp_dir: dir} do
    test = self()

    refresh = fn d, p ->
      send(test, {:refreshed, p})

      Usage.put_endpoint(
        d,
        p,
        %{"5h" => %{"label" => "5 hours", "used" => 77.0, "resets_at" => nil}},
        "pro"
      )
    end

    view = mount_usage(dir, %{signed_in: [:openai_codex], refresh: refresh})
    assert text(view) =~ "asking the usage endpoint…"
    assert_receive {:refreshed, :openai_codex}
    assert_receive {:operator_usage, :openai_codex, :ok} = done
    view = render_info(view, done)
    shown = text(view)
    assert shown =~ "5 hours  [########..] 77%"
    assert shown =~ "plan pro · from the usage endpoint"
    refute shown =~ "asking the usage endpoint"
    # fresh numbers: no ask on open, only on [refresh]; its error shows
    failing = fn _d, p -> send(test, {:refreshed, p}) && {:error, "HTTP 429"} end
    view = mount_usage(dir, %{signed_in: [:openai_codex], refresh: failing})
    refute_receive {:refreshed, _}, 50
    view = render_info(view, {:tap, :refresh})
    assert_receive {:operator_usage, :openai_codex, {:error, _}} = failed
    assert text(render_info(view, failed)) =~ "usage endpoint: HTTP 429"
  end
end
