-module(flujo_http).
-export([get_binary/1]).

get_binary(Url) ->
    application:ensure_all_started(inets),
    Options = [{timeout, 120000}, {connect_timeout, 5000}],
    case httpc:request(
        get,
        {binary_to_list(Url), []},
        Options,
        [{body_format, binary}]
    ) of
        {ok, {{_Version, Status, _Reason}, Headers, Body}} ->
            ContentType = proplists:get_value(
                "content-type",
                Headers,
                "application/octet-stream"
            ),
            {ok, {Status, list_to_binary(ContentType), Body}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.
