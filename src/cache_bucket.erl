%%
-module(cache_bucket).
-behaviour(gen_server).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-include("cache.hrl").

-export([
   start_link/2,
   init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3
]).

%%
%%
-record(cache, {
   name   :: atom(),     %% name of cache bucket
   heap   :: list(),     %% heap

   n      = ?DEF_CACHE_N      :: integer(),  %% number of cells          
   ttl    = ?DEF_CACHE_TTL    :: integer(),  %% chunk time to live
   policy = ?DEF_CACHE_POLICY :: integer(),  %% eviction policy
   evict                      :: integer(),  %% age of heap cell (cell eviction frequency)

   quota  = ?DEF_CACHE_QUOTA  :: integer(),  %% frequency of limit enforcement (clean-up)
   quota_size   :: integer(),  %% max number of elements
   quota_memory :: integer()   %% max number of memory in bytes
}).

%%
%%
start_link(Name, Opts) ->
   gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).

init([Name, Opts]) ->
   {ok, init(Opts, #cache{name=Name})}.

init([{policy, X} | T], #cache{}=S) ->
   init(T, S#cache{policy=X});

init([{memory, X} | Opts], S) ->
   init(Opts, S#cache{quota_memory=X div erlang:system_info(wordsize)});

init([{size,  X} | Opts],  S) ->
   init(Opts, S#cache{quota_size=X});

init([{n,   X} | Opts], S) ->
   init(Opts, S#cache{n = X});

init([{ttl, X} | Opts], S) ->
   init(Opts, S#cache{ttl = X});

init([{quota, X} | Opts], S) ->
   init(Opts, S#cache{quota=X * 1000});

init([_ | Opts], S) ->
   init(Opts, S);

init([], S) ->
   random:seed(erlang:now()),
   Evict = (S#cache.ttl div S#cache.n) * 1000,
   erlang:send_after(S#cache.quota, self(), quota),
   erlang:send_after(Evict, self(), evict),
   S#cache{
      heap  = cache_heap:new(S#cache.n),
      evict = Evict
   }.

%%
%%     
terminate(_Reason, S) ->
   cache_heap:free(S#cache.heap),
   ok.

%%%----------------------------------------------------------------------------   
%%%
%%% gen_server
%%%
%%%----------------------------------------------------------------------------   

handle_call({put, Key, Val}, _, S) ->
   {reply, ok, insert(Key, Val, S)};

handle_call({get, Key}, _, S) ->
   {reply, lookup(Key, S), S};

handle_call({has, Key}, _, S) ->
   case member(Key, S) of
      true -> {reply, true,  S};
      _    -> {reply, false, S}
   end;

handle_call({remove, Key}, _, S) ->
   {reply, ok, remove(Key, S)};

handle_call(i, _, S) ->
   Cells  = cache_heap:cells(S#cache.heap), 
   Size   = cache_heap:size(S#cache.heap), 
   Memory = cache_heap:memory(S#cache.heap), 
   {reply, [{heap, Cells}, {size, Size}, {memory, Memory}], S};

handle_call(_, _, S) ->
   {noreply, S}.

%%
%%
handle_cast({put, Key, Val}, S) ->
   {noreply, insert(Key, Val, S)};

handle_cast({remove, Key}, S) ->
   {noreply, remove(Key, S)};

handle_cast(_, S) ->
   {noreply, S}.

handle_info(evict, S) ->
   erlang:send_after(S#cache.evict, self(), evict),
   {noreply, evict(S)};

handle_info(quota, S) ->
   erlang:send_after(S#cache.quota, self(), quota),
   {noreply, quota(S)};

handle_info(_, S) ->
   {noreply, S}.

%%
%% 
code_change(_Vsn, S, _Extra) ->
   {ok, S}.


%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% evict key from cells 
evict_key(Key, List) ->
   dowhile(
      fun(Cell) -> 
         case ets:member(Cell, Key) of
            true   -> 
               ets:delete(Cell, Key),
               Cell;
            Result -> 
               Result
         end
      end,
      List
   ).

%%
%%
insert(Key, Val, #cache{}=S) ->
   [Head | Tail] = cache_heap:cells(S#cache.heap),
   true = ets:insert(Head, {Key, Val}),
   _    = evict_key(Key, Tail),
   ?DEBUG("cache ~p: put ~p to cell ~p~n", [S#cache.name, Key, Head]),
   S.

%%
%%
remove(Key, S) ->
   Cell = evict_key(Key, cache_heap:cells(S#cache.heap)),
   ?DEBUG("cache ~p: remove ~p in cell ~p~n", [S#cache.name, Key, Cell]),
   S.

%%
%%
member(Key, S) ->
   dowhile(
      fun(X) -> ets:member(X, Key) end,
      cache_heap:cells(S#cache.heap)
   ).  

%%
%%
lookup(Key, #cache{policy=mru}=S) ->
   % cache always evicts last generation
   % MRU caches do not prolong recently used entity
   dowhile(
      fun(Cell) ->
         case ets:lookup(Cell, Key) of
            [] ->
               false;
            [{_, Val}] ->
               ?DEBUG("cache ~p: get ~p at cell ~p~n", [S#cache.name, Key, Cell]),
               Val
         end
      end,
      lists:reverse(cache_heap:cells(S#cache.heap))
   );

lookup(Key, S) ->
   [Head | Tail] = cache_heap:cells(S#cache.heap),
   case ets:lookup(Head, Key) of
      % no value at head chunk, lookup and evict tail 
      [] ->
         dowhile(
            fun(Cell) ->
               case ets:lookup(Cell, Key) of
                  [] ->
                     false;
                  [{_, Val}] ->
                     ?DEBUG("cache ~p: get ~p at cell ~p~n", [S#cache.name, Key, Cell]),
                     _    = ets:delete(Cell, Key),
                     true = ets:insert(Head, {Key, Val}),
                     Val
               end
            end,
            Tail
         );
      [{_, Val}] -> 
         ?DEBUG("cache ~p: get ~p in cell ~p~n", [S#cache.name, Key, Head]),
         Val
   end.

%%
%% execute predicate while it succeeded
dowhile(Pred, [Head | Tail]) ->
   case Pred(Head) of
      % predicate false, apply predicate to next chunk
      false  -> dowhile(Pred, Tail);
      Result -> Result
   end;

dowhile(_Pred, []) ->
   undefined.

%%
%%
evict(#cache{}=S) ->
   Cell = cache_heap:last(S#cache.heap),
   ?DEBUG("cache ~p: free cell ~p~n", [S#cache.name, Cell]),
   S#cache{
      heap = cache_heap:alloc(cache_heap:free(Cell, S#cache.heap))
   }.

%%
%%
quota(#cache{}=S) ->
   maybe_memory_quota(
      maybe_size_quota(S)
   ).


maybe_size_quota(#cache{quota_size=undefined}=S) ->
   S;
maybe_size_quota(S) ->
   Quota      = S#cache.quota_size div S#cache.n,
   [Head | _] = cache_heap:cells(S#cache.heap),
   case ets:info(Head, size) of
      Val when Val >= Quota ->
         evict(S);
      _ ->
         S
   end.

maybe_memory_quota(#cache{quota_memory=undefined}=S) ->
   S;
maybe_memory_quota(S) ->
   Quota      = S#cache.quota_size div S#cache.n,
   [Head | _] = cache_heap:cells(S#cache.heap),
   case ets:info(Head, memory) of
      Val when Val >= Quota ->
         evict(S);
      _ ->
         S
   end.
