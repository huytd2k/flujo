-module(flujo_docker).
-export([run/1]).

run(Args) ->
    Docker = case os:find_executable("docker") of
        false -> <<>>;
        Path -> list_to_binary(Path)
    end,
    case Docker of
        <<>> -> {error, <<"docker_not_found">>};
        _ ->
            Port = open_port(
                {spawn_executable, binary_to_list(Docker)},
                [binary, exit_status, stderr_to_stdout, use_stdio,
                 {args, [binary_to_list(A) || A <- Args]}]
            ),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, trim(iolist_to_binary(lists:reverse(Acc)))};
        {Port, {exit_status, _}} -> {error, trim(iolist_to_binary(lists:reverse(Acc)))}
    after 120000 ->
        port_close(Port),
        {error, <<"docker_timeout">>}
    end.

trim(Value) -> list_to_binary(string:trim(binary_to_list(Value))).
