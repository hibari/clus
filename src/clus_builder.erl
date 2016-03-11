%%%-------------------------------------------------------------------
%%% Copyright (c) 2011-2016 Hibari developers.  All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% File    : clus_builder.erl
%%% Purpose : Cluster Builder (includes bits of Jungerl buildler.erl)
%%%-------------------------------------------------------------------

-module(clus_builder).

%% API
-export([init/0, init/1]).

-include_lib("kernel/include/file.hrl").


%%%===================================================================
%%% API
%%%===================================================================

init() ->
    init([]).

init(Options) ->
    %% We use a dictionary for the options. The options are
    %% prioritized in the following order: (1) those given as
    %% arguments to the go/1 function, those in the clus.config file,
    %% and (3) the hard-coded defaults.  The options stored last in
    %% the dictionary take precedence, but since we want to allow for
    %% the Options list to guide us in finding the clus.config file
    %% (under certain circumstances), we store the defaults and
    %% Options list in the dictionary, then locate and read the file,
    %% then store the Options list again.
    Dict0 = mk_dict(default_options() ++ Options),
    Dict = with(Dict0,
                [
                 %% options
                 fun(D) -> read_options_file(D) end
                 , fun(D) -> store_options(Options, D) end
                 , fun(D) -> post_process_options(D) end
                 %%
                ]),
    Res = do_init(Dict),
    Res.

%%%===================================================================
%%% Internal functions
%%%===================================================================

do_init(Dict) ->
    {ok, User} = dict:find(node_user, Dict),
    {ok, Nodes} = dict:find(nodes, Dict),

    {ok, Force} = dict:find(initsh_force, Dict),
    {ok, Limit} = dict:find(initsh_pmap_limit, Dict),
    {ok, Timeout} = dict:find(initsh_pmap_timeout, Dict),

    Cmds = [ begin
                 [filename:join([code:priv_dir(clus), "clus.sh"])
                  , if Force -> " -f"; true -> " " end
                  , " ", "init"
                  , " ", User
                  , " ", atom_to_list(Node)
                 ]
             end || Node <- Nodes ],
    Fun = fun(Cmd) -> os:cmd(Cmd) end,
    Res = gmt_pmap:pmap(Fun, Cmds, Limit, Timeout),
    Res.


default_options() ->
    [{initsh_force, false}
     , {initsh_pmap_limit, 20}
     , {initsh_pmap_timeout, 1000}
     , {rel_dir, cwd()}
     , {erlang_dir, code:root_dir()}
    ].


read_options_file(Dict) ->
    case dict:find(clus_options, Dict) of
        {ok, BuildOptsF} ->
            case script(BuildOptsF) of
                {error, empty_script} ->
                    %% We accept this
                    Dict;
                {ok, Terms} ->
                    store_options(Terms, Dict);
                {error, Reason} ->
                    exit({bad_options_file, {BuildOptsF, Reason}})
            end;
        error ->
            Path =
                case dict:find(rel_dir, Dict) of
                    {ok, RelDir} ->
                        [RelDir, "rel"];
                    error ->
                        [".", "rel"]
                end,
            case path_script(Path, "clus.config") of
                {ok, Terms, _Fullname} ->
                    Dict1 = store_options(Terms, Dict),
                    Dict1;
                {error, enoent} ->
                    Dict;
                Error ->
                    exit({clus_options, Error})
            end
    end.


store_options(Options, Dict) ->
    lists:foldl(
      fun({Key,Value}, D) ->
              dict:store(Key,Value,D)
      end, Dict, Options).


post_process_options(Dict) ->
    D = with(Dict,
             [fun(D) -> case dict:find(node_user, D) of
                            {ok,_} -> D;
                            error -> exit(missing_node_user_option)
                        end
              end,
              fun(D) -> case dict:find(nodes, D) of
                            {ok,Nodes} ->
                                case lists:sort(Nodes) == lists:usort(Nodes) of
                                    true ->
                                        D;
                                    false ->
                                        exit({bad_nodes_option, Nodes})
                                end;
                            error -> exit(missing_nodes_option)
                        end
              end
             ]),
    D.


mk_dict(Options) ->
    store_options(Options, dict:new()).


with(Dict, Actions) ->
    lists:foldl(fun(F,D) ->
                        F(D)
                end, Dict, Actions).


cwd() ->
    {ok, CWD} = file:get_cwd(),
    CWD.


script(File) ->
    script(File, erl_eval:new_bindings()).

script(File, Bs) ->
    case file:open(File, [read]) of
        {ok, Fd} ->
            Bs1 = erl_eval:add_binding('ScriptName',File,Bs),
            R = case eval_stream(Fd, Bs1) of
                    {ok, Result} ->
                        {ok, Result};
                    Error ->
                        Error
                end,
            ok = file:close(Fd),
            R;
        Error ->
            Error
    end.

path_script(Path, File) ->
    path_script(Path, File, erl_eval:new_bindings()).

path_script(Path, File, Bs) ->
    case file:path_open(Path, File, [read]) of
        {ok,Fd,Full} ->
            Bs1 = erl_eval:add_binding('ScriptName',Full,Bs),
            case eval_stream(Fd, Bs1) of
                {error,E} ->
                    ok = file:close(Fd),
                    {error, {E, Full}};
                {ok, R} ->
                    ok = file:close(Fd),
                    {ok,R,Full}
            end;
        Error ->
            Error
    end.

eval_stream(Fd, Bs) ->
    eval_stream(Fd, undefined, Bs).

eval_stream(Fd, Last, Bs) ->
    eval_stream(io:parse_erl_exprs(Fd, ''), Fd, Last, Bs).


eval_stream({ok,Form,_EndLine}, Fd, _Last, Bs0) ->
    case catch erl_eval:exprs(Form, Bs0) of
        {value,V,Bs} ->
            eval_stream(Fd, {V}, Bs);
        {'EXIT',Reason} ->
            {error, Reason}
    end;
eval_stream({error,What,EndLine}, _Fd, _L, _Bs) ->
    {error, {parse_error, {What,EndLine}}};
eval_stream({eof,_EndLine}, _Fd, Last, _Bs) ->
    case Last of
        {Val} ->
            {ok, Val};
        undefined ->
            %% empty script
            {error, empty_script}
    end.
