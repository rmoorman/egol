-module(egol_eqc).
 
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-record(state,
  { cell,
    id,
    dim,
    content,
    time=0,
    steps=0,
    collector,
    waiting_on = undefined,
    neighbour_count = 0,
    neighbour_history = [],
    kill_count=0
  }).


api_spec() ->
  #api_spec{
     language = erlang,
     modules  = [
                  #api_module{
                     name = egol_protocol,
                     functions = [ #api_fun{ name = query_content, arity = 2},
                                   #api_fun{ name = query_response, arity = 2}
                                 ]
                    }
                ]}.
  


initial_state() ->
  #state{}.

%% @doc Default generated property
-spec prop_cell() -> eqc:property().
prop_cell() ->
  ?SETUP( %%fun my_setup/0, 
fun() -> 
             %% setup mocking here
             eqc_mocking:start_mocking(api_spec()),
             fun() -> ok end
         end, 
  ?FORALL(Cmds, commands(?MODULE),
 %         ?IMPLIES(length(Cmds)>20,
          begin
            start(),
            {H, S, Res} = run_commands(?MODULE,Cmds),
            stop(S),
            pretty_commands(?MODULE, Cmds, {H, S, Res},
                            aggregate(command_names(Cmds),
                                      Res == ok))
          end))
%)
.

my_setup() ->
  start(),
  fun() -> stop end.
      

start() ->
  catch egol_time:stop(),
  egol_sup:start_link(),
  ok.

stop() ->
%%  print_regs(),
  catch exit(whereis(egol_sup), normal),
  catch egol_time:stop(),
  eqc_mocking:stop_mocking(),
  timer:sleep(100),
  ok.

print_regs() ->
  try
    CellSup = whereis(cell_sup),
    MgrSup  = whereis(mgr_sup),
    io:format("CellSup: ~p - MgrSup: ~p~n", [CellSup, MgrSup])
  catch
    _:_ ->
      io:format("unable to print regs~n")
  end.

stop(S) ->
  catch exit(S#state.cell, normal),
  catch exit(S#state.collector, normal),
  timer:sleep(100).


%%weight(_S, kill) -> 0;
weight(#state{id=undefined}, Cmd) when Cmd /= cell -> 0;
weight(#state{waiting_on=W}, step) when is_list(W) -> 0;
weight(_S, get) -> 1;
weight(_S, cell) -> 1;
weight(_S, requery_response) -> 20;
%weight(_S, complete_step) -> 0;
weight(_S, kill) -> 3; 
weight(_S, _) -> 2.
   


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
cell(XY, Dim, Content) ->
  {ok, Pid} = egol_cell_sup:start_cell(XY, Dim, Content),
  %io:format("cell STARTED ~p (~p/~p)~n", [Pid, XY, Dim]),
  Pid.

cell_args(_S) ->
  ?LET({CellId, Dim}, cell_id_and_dim(),
       [CellId, Dim, content()]).

cell_pre(S, _) ->
  S#state.cell == undefined.

cell_post(_S, [_, _, _], Res) ->
  is_pid(Res) and erlang:is_process_alive(Res).


cell_next(S, Pid, [CellId, Dim, Content]) ->
  S#state{cell=Pid, id=CellId, dim=Dim, content=Content}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
step(Pid, Id, _Time) ->
  %io:format("step for ~p/~p~n", [Pid, Id]),
  egol_cell:step(Id),
  Res = egol_cell:collector(Id),
  timer:sleep(100),
  Res.

step_args(S) ->
  [S#state.cell, S#state.id, S#state.time].

step_pre(S, [Pid, Id, _]) ->
  %% %io:format("step_pre cell:~p, pid:~p waiting_on:~p~n",
  %%           [S#state.cell, Pid, S#state.waiting_on]), 
  S#state.id /= undefined andalso
%%  S#state.cell == Pid  andalso 
    S#state.id == Id andalso
    S#state.waiting_on == undefined.

step_callouts(S, [_Pid, _XY, _Time ]) ->
  step_callouts_for_time(S#state.time).

step_callouts_for_time(Time) ->
    ?PAR(lists:duplicate(8, ?CALLOUT(egol_protocol, query_content, [?WILDCARD, Time], ok))).

%% step_return(_S, _) ->
%%   ok.

step_next(S, Res, _Args) ->
%  %io:format("step_next time:~p~n", [S#state.time]),
  S#state{waiting_on = egol_util:neighbours_at(S#state.time, 
                                               egol_util:neighbours(S#state.id, S#state.dim)),
          collector=Res,
          steps=S#state.steps+1}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
get(Id, Time) ->
  Res = egol_cell:get(Id, Time),
%  %io:format("get works~n"),
  Res.

get_args(S) ->
  [S#state.id, S#state.time].

get_pre(S, [Id, Time]) ->
  S#state.id /= undefined andalso
    S#state.id == Id andalso
    S#state.time == Time.

get_post(S, [_Id, _Time], Res) ->
  Res == S#state.content.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
query_response(Pid, Resp) ->
  %io:format("query_response(~p)~n", [Pid]),
  send_query_response(Pid, Resp).
  
query_response_args(#state{id=undefined}) ->
      [undefined, undefined];
query_response_args(#state{cell=Cell, waiting_on=undefined}) when is_pid(Cell) ->
      [undefined, undefined];
query_response_args(S) ->
  [S#state.collector, {{neighbour(S), S#state.time}, content()}].

query_response_pre(#state{waiting_on=undefined}, _ ) -> false;    
query_response_pre(S, [Collector, {{Neighbour, Time}, _}] ) ->
  Collector /= undefined andalso
  S#state.waiting_on /= [] andalso
  lists:member({Neighbour, Time}, S#state.waiting_on) andalso
    Time == S#state.time.

query_response_next(S, _Res, [_, {{Neighbour, Time}, Content}=Resp]) ->
  NC = S#state.neighbour_count + Content,
  case lists:delete({Neighbour, Time}, S#state.waiting_on) of
    [] ->
      timer:sleep(100),
      io:format("got ALL neighbour contents=~p~n",[NC]),
      S#state{content=next_content(S#state.content, NC),
              time=Time+1,
              waiting_on=undefined,
              collector=undefined,
              neighbour_count=0,
              neighbour_history=S#state.neighbour_history ++ [Resp]};
    Wait ->
      S#state{waiting_on = Wait, neighbour_count = NC,
              neighbour_history=S#state.neighbour_history ++ [Resp]}
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
kill(Id, 0, _) ->
  try 
    egol_cell:kill(Id),
    timer:sleep(500),
    Pid = egol_cell_mgr:lookup(Id),
    Collector = undefined,
    %{Pid, Collector}
    Pid
  catch
    E:M ->
      io:format("kill exception ~p:~p ~p~n", [E, M, erlang:get_stacktrace()])
  end;
kill(Id, EndTime, NeighbourHistory) ->
  try
    egol_cell:kill(Id),
    timer:sleep(100),
    Pid = egol_cell_mgr:lookup(Id),
    %io:format("kill new_pid:~p~n", [Pid]),
    Collector = egol_cell:collector(Pid),
    %io:format("new collector: ~p~n", [Collector]),
    drive_collector(Pid, Collector, 0, EndTime, NeighbourHistory),
%    {Pid, LastCollector}
    Pid
  catch
    E:M ->
      io:format("kill exception ~p:~p ~p~n", [E, M, erlang:get_stacktrace()])
  end.

%% go forward until the cell has progressed to max time
drive_collector(_Pid, Collector, T, T, _NeighbourHistory) ->
  Collector;
%%send_all_query_responses(Collector, NeighbourHistory);
drive_collector(Pid, Collector, T, EndTime, NeighbourHistory) ->
  %% @todo consider filtering out the CellContents not for this time step, though
  %% they should do no harm.
  ResponsesForTime = [ R 
                      || {{_,RTime},_}=R <- NeighbourHistory,
                         RTime == T ],
  send_all_query_responses(Collector, ResponsesForTime),
  timer:sleep(100),
  NewCollector = egol_cell:collector(Pid),
  drive_collector(Pid, NewCollector, T+1, EndTime, NeighbourHistory).

send_all_query_responses(Collector, NeighbourHistory) ->
    lists:foreach(fun(CellContent) ->
                      send_query_response(Collector, CellContent)
                  end,
                  NeighbourHistory).

kill_args(#state{id=Id, time=Time, neighbour_history=NH}) ->
  [Id, Time, NH].

kill_pre(S, [Id, EndTime, _]) ->
  S#state.cell /= undefined andalso
    S#state.id == Id andalso 
    S#state.time == EndTime andalso
    S#state.kill_count<1.


kill_callouts(_S, [_Id, 0, _]) ->
  ?EMPTY;
kill_callouts(_S, [_Id, EndTime, _NH]) ->
  ?SEQ( [ step_callouts_for_time(T) 
          || T <- lists:seq(0, EndTime-1) ] ).

%% after a kill the cell will run up to the EndTime and then await a step before it
%% can continue since it has not received a step command to drive it forward, so
%% waiting_on has to be undefined.
kill_next(S, Pid, %{Pid, Collector}, 
          [_Id, EndTime, _NH]) ->
  S#state{cell=Pid, collector=undefined, 
          waiting_on=undefined,
          kill_count=S#state.kill_count+1}.
    


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% GENERATORS
cell_id_and_dim() ->
  ?LET({DimX, DimY}, {dim(),dim()},
       ?LET({X,Y}, {coord(DimX), coord(DimY)},
            {{X,Y},{DimX,DimY}})).

dim() ->
  ?SUCHTHAT(N, nat(), N>2).

coord(Max) ->
  choose(0, Max-1).

pos_int() ->
  ?LET(N, nat(), N+1).

content() ->
  choose(0,1).

neighbour(S) ->
  oneof(egol_util:neighbours(S#state.id, S#state.dim)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% HELPERS

next_content(0,3) -> 1;
next_content(C, N) when N==2; N==3 -> C;
next_content(_,_) -> 0.
  
send_query_response(Pid, {{_XY,_T}, _C}=Resp) ->
  try
    Pid ! {cell_content, Resp}
  catch
    _:_ ->
      io:format("send_query_response (~p, ~p) failed~n", 
                [Pid, Resp])
  end.
