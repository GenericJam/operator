%% operator.erl — BEAM bootstrap for Operator.
%% Called by the iOS/Android native launcher via -eval 'operator:start().'.
%% Starts the OTP ecosystem in order, then hands off to the Elixir app module.
-module(operator).
-export([start/0]).

start() ->
    step(1, fun() -> application:start(compiler) end),
    step(2, fun() -> application:start(elixir)   end),
    step(3, fun() -> application:start(logger)   end),
    step(4, fun() -> mob_nif:platform()          end),
    %% The update server set on this phone (Operator.Deliver): mob_deliver
    %% reads it when Operator.App.start/0 starts mob's plugins, and only
    %% starts its update checks with one. Never delivered over the air:
    %% this module runs before anything delivered is loaded.
    step(5, fun() -> 'Elixir.Operator.Deliver':apply_saved_endpoint() end),
    step(6, fun() -> 'Elixir.Operator.App':start() end),
    timer:sleep(infinity).

step(N, Fun) ->
    mob_nif:log("step " ++ integer_to_list(N) ++ " starting"),
    %% Wrap to keep going after a step throws — we still want the log
    %% line below to print so the user can see which step failed. Was
    %% `(catch Fun())` before OTP 28 deprecated the classic catch
    %% syntax. The `try Class:Reason` form catches all three exception
    %% classes (throw / exit / error) and tags them so the log
    %% formatter prints something readable.
    Result = try Fun()
             catch Class:Reason -> {Class, Reason}
             end,
    mob_nif:log("step " ++ integer_to_list(N) ++ " => " ++
                lists:flatten(io_lib:format("~p", [Result]))).
